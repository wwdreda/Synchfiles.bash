#!/bin/bash

# Help function
usage() {
    echo "Usage: $0 [-i] [-d] path1 path2"
    echo "  -i    Interactive mode. Ask for confirmation before overwriting files."
    echo "  -d    Dry run. Show what would be done, without actually doing it."
    exit 1
}

# Parse options
interactive=0
dryrun=0
while getopts "idh" opt; do
    case ${opt} in
        i)
            interactive=1
            ;;
        d)
            dryrun=1
            ;;
        h)
            usage
            ;;
        \?)
            usage
            ;;
    esac
done
shift $((OPTIND -1))

# Check number of arguments
if [[ $# -ne 2 ]]; then
    usage
fi

# Vérifier si le script est exécuté en tant que root
if [[ $EUID -ne 0 ]]; then
   echo "Ce script doit être exécuté en tant que root"
   exit 1
fi

# Vérifier si le nombre correct d'arguments a été fourni
if [[ $# -ne 2 ]]; then
    echo "Usage : $0 path1 path2"
    exit 1
fi

# Les chemins vers les systèmes de fichiers A et B
pathA=$1
pathB=$2

# Liste des fichiers/répertoires à exclure de la synchronisation
exclusions=("fichier_temporaire.txt" "cache")

# Compteur pour les liens symboliques synchronisés
liensSymboliques=0

# Variables pour le résumé de la synchronisation
totalFiles=0
filesCopiedFromAtoB=0
filesCopiedFromBtoA=0
conflictsResolved=0

# Fonction pour vérifier si un fichier/répertoire doit être exclu
est_exclu() {
    for exclusion in "${exclusions[@]}"; do
        if [[ $1 == *"$exclusion"* ]]; then
            return 0
        fi
    done
    return 1
}

# Fonction pour synchroniser les fichiers
synchroniser() {
    local pathA=$1
    local pathB=$2

    # Parcourir tous les fichiers dans le système de fichiers A
    for fichierA in "$pathA"/*; do
        # Vérifier si le fichier/répertoire est dans la liste des exclusions
        if est_exclu "$fichierA"; then
            echo "Exclusion : $fichierA"
            continue
        fi
        # Obtenir le nom du fichier
        nomFichier=$(basename "$fichierA")
        # Chemin vers le fichier correspondant dans le système de fichiers B
        fichierB="$pathB/$nomFichier"
        # Vérifier si le fichier existe dans le système de fichiers B
        if [[ -e $fichierB ]]; then
            # Si le fichier est plus grand que 1GB
            if [[ $(stat -c%s "$fichierA") -gt 1073741824 ]]; then
                echo "Le fichier $nomFichier est très grand et peut prendre du temps à synchroniser."
                echo "Voulez-vous continuer la synchronisation de ce fichier ? (Oui/Non)"
                read reponse
                if [[ $reponse == "Non" ]]; then
                    echo "Exclusion : $fichierA"
                    continue
                fi
            fi
            # Si les deux fichiers sont des répertoires, descendre récursivement
            if [[ -d $fichierA && -d $fichierB ]]; then
                synchroniser "$fichierA" "$fichierB"
            # Si les deux fichiers sont des fichiers ordinaires et ont le même hachage SHA, il n'y a rien à faire
            elif [[ -f $fichierA && -f $fichierB && $(shasum "$fichierA") == $(shasum "$fichierB") ]]; then
                echo "Le fichier $nomFichier est déjà synchronisé."
            else
                # Conflit détecté
                echo "Conflit détecté pour le fichier $nomFichier."
                ((conflictsResolved++))
                # Comparer le contenu des fichiers
                if cmp -s "$fichierA" "$fichierB"; then
                    echo "Les fichiers ont le même contenu, mais diffèrent dans les métadonnées."
                    # Résoudre le conflit en copiant les métadonnées du fichier qui est conforme au journal
                    if [[ $(shasum "$fichierA") == $(cat "$HOME/.synchro/$(basename $pathA)_$nomFichier") ]]; then
                        chown --reference="$fichierA" "$fichierB"
                        chmod --reference="$fichierA" "$fichierB"
                        touch --reference="$fichierA" "$fichierB"
                        echo "Les métadonnées du fichier B ont été mises à jour pour correspondre à celles du fichier A."
                    else
                        chown --reference="$fichierB" "$fichierA"
                        chmod --reference="$fichierB" "$fichierA"
                        touch --reference="$fichierB" "$fichierA"
                        echo "Les métadonnées du fichier A ont été mises à jour pour correspondre à celles du fichier B."
                    fi
                else
                    echo "Les fichiers ont un contenu différent. Voici la différence :"
                    diff "$fichierA" "$fichierB"
                    echo "Veuillez entrer le chemin du fichier que vous souhaitez conserver :"
                    read fichierConserve
                    if [[ $fichierConserve == $fichierA ]]; then
                        if [[ $interactive -eq 1 ]]; then
                            echo "Voulez-vous écraser $fichierB avec $fichierA ? (o/n)"
                            read response
                            if [[ $response != "o" ]]; then
                                echo "Ignorer $fichierA"
                                continue
                            fi
                        fi
                        if [[ $dryrun -eq 1 ]]; then
                            echo "Copierait $fichierA vers $fichierB"
                        else
                            cp -d "$fichierA" "$fichierB"
                            echo "Le fichier $nomFichier a été copié de A vers B."
                            ((filesCopiedFromAtoB++))
                            ((totalFiles++))
                        fi
                    else
                        if [[ $interactive -eq 1 ]]; then
                            echo "Voulez-vous écraser $fichierA avec $fichierB ? (o/n)"
                            read response
                            if [[ $response != "o" ]]; then
                                echo "Ignorer $fichierB"
                                continue
                            fi
                        fi
                        if [[ $dryrun -eq 1 ]]; then
                            echo "Copierait $fichierB vers $fichierA"
                        else
                            cp -d "$fichierB" "$fichierA"
                            echo "Le fichier $nomFichier a été copié de B vers A."
                            cp -d "$fichierB" "$fichierA"
                            echo "Le fichier $nomFichier a été copié de B vers A."
                            ((filesCopiedFromBtoA++))
                            ((totalFiles++))
                        fi
                    fi
                fi
            fi
        else
            # Copier le fichier de A vers B
            if [[ $interactive -eq 1 ]]; then
                echo "Voulez-vous copier $fichierA vers $fichierB ? (o/n)"
                read response
                if [[ $response != "o" ]]; then
                    echo "Ignorer $fichierA"
                    continue
                fi
            fi
            if [[ $dryrun -eq 1 ]]; then
                echo "Copierait $fichierA vers $fichierB"
            else
                cp -d "$fichierA" "$fichierB"
                echo "Le fichier $nomFichier a été copié de A vers B."
                ((filesCopiedFromAtoB++))
                ((totalFiles++))
            fi
            # Si le fichier est un lien symbolique, incrémenter le compteur
            if [[ -L $fichierA ]]; then
                ((liensSymboliques++))
            fi
        fi
        # Mettre à jour le journal avec le hachage SHA du fichier synchronisé
        echo "$(shasum "$fichierA") $fichierA" > "$HOME/.synchro/$(basename $pathA)_$nomFichier"
        echo "Synchronisation effectuée le $(date)" >> "$HOME/.synchro/$(basename $pathA)_$nomFichier"
        echo ""
    done

    # Parcourir tous les fichiers dans le système de fichiers B
    for fichierB in "$pathB"/*; do
        # Vérifier si le fichier/répertoire est dans la liste des exclusions
        if est_exclu "$fichierB"; then
            echo "Exclusion : $fichierB"
            continue
        fi
        # Obtenir le nom du fichier
        nomFichier=$(basename "$fichierB")
        # Chemin vers le fichier correspondant dans le système de fichiers A
        fichierA="$pathA/$nomFichier"
        # Vérifier si le fichier existe dans le système de fichiers A
        if [[ ! -e $fichierA ]]; then
            # Si le fichier est plus grand que 1GB
            if [[ $(stat -c%s "$fichierB") -gt 1073741824 ]]; then
                echo "Le fichier $nomFichier est très grand et peut prendre du temps à synchroniser."
                echo "Voulez-vous continuer la synchronisation de ce fichier ? (Oui/Non)"
                read reponse
                if [[ $reponse == "Non" ]]; then
                    echo "Exclusion : $fichierB"
                    continue
                fi
            fi
            # Copier le fichier de B vers A
            if [[ $interactive -eq 1 ]]; then
                echo "Voulez-vous copier $fichierB vers $fichierA ? (o/n)"
                read response
                if [[ $response != "o" ]]; then
                    echo "Ignorer $fichierB"
                    continue
                fi
            fi
            if [[ $dryrun -eq 1 ]]; then
                echo "Copierait $fichierB vers $fichierA"
            else
                cp -d "$fichierB" "$fichierA"
                echo "Le fichier $nomFichier a été copié de B vers A."
                ((filesCopiedFromBtoA++))
                ((totalFiles++))
            fi
            # Si le fichier est un lien symbolique, incrémenter le compteur
            if [[ -L $fichierB ]]; then
                ((liensSymboliques++))
            fi
        fi
        # Mettre à jour le journal avec le hachage SHA du fichier synchronisé
        echo "$(shasum "$fichierB") $fichierB" > "$HOME/.synchro/$(basename $pathB)_$nomFichier"
        echo "Synchronisation effectuée le $(date)" >> "$HOME/.synchro/$(basename $pathB)_$nomFichier"
        echo ""
    done
}

# Créer le répertoire pour le fichier journal sil n'existe pas
mkdir -p "$HOME/.synchro"

# Appeler la fonction de synchronisation
synchroniser $pathA $pathB

# Afficher le résumé de la synchronisation
echo "----------------------------------------"
echo "RÉSUMÉ DE LA SYNCHRONISATION"
echo "----------------------------------------"
echo "Nombre total de fichiers synchronisés : $totalFiles"
echo "Fichiers copiés de A vers B : $filesCopiedFromAtoB"
echo "Fichiers copiés de B vers A : $filesCopiedFromBtoA"
echo "Conflits résolus : $conflictsResolved"
echo "----------------------------------------"

