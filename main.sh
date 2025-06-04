#!/bin/bash

# IBM Cloud User Management Script
# Lädt E-Mail-Adressen aus einer Datei und fügt Benutzer zu einer Admin-Zugriffsgruppe hinzu

set -e  # Script bei Fehlern beenden

# Konfigurationsvariablen
EMAIL_FILE="user_emails.txt"
ACCESS_GROUP_NAME="Admin-Full-Access-Group"
ACCESS_GROUP_DESCRIPTION="Vollständige Administratorrechte für alle IBM Cloud Services"

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging-Funktion
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Überprüfung der Voraussetzungen
check_prerequisites() {
    log "Überprüfung der Voraussetzungen..."
    
    # IBM Cloud CLI verfügbar?
    if ! command -v ibmcloud &> /dev/null; then
        error "IBM Cloud CLI ist nicht installiert. Bitte installieren Sie es von https://cloud.ibm.com/docs/cli"
        exit 1
    fi
    
    # Anmeldestatus prüfen
    if ! ibmcloud account show &> /dev/null; then
        error "Sie sind nicht bei IBM Cloud angemeldet. Bitte führen Sie 'ibmcloud login' aus."
        exit 1
    fi
    
    # E-Mail-Datei existiert?
    if [[ ! -f "$EMAIL_FILE" ]]; then
        error "E-Mail-Datei '$EMAIL_FILE' nicht gefunden!"
        echo "Erstellen Sie eine Datei mit E-Mail-Adressen (eine pro Zeile):"
        echo "user1@example.com"
        echo "user2@example.com"
        exit 1
    fi
    
    success "Alle Voraussetzungen erfüllt."
}

# Zugriffsgruppe erstellen
create_access_group() {
    log "Erstelle Zugriffsgruppe '$ACCESS_GROUP_NAME'..."
    
    # Prüfen ob Gruppe bereits existiert
    if ibmcloud iam access-groups | grep -q "$ACCESS_GROUP_NAME"; then
        warning "Zugriffsgruppe '$ACCESS_GROUP_NAME' existiert bereits."
        return 0
    fi
    
    # Neue Zugriffsgruppe erstellen
    if ibmcloud iam access-group-create "$ACCESS_GROUP_NAME" -d "$ACCESS_GROUP_DESCRIPTION"; then
        success "Zugriffsgruppe '$ACCESS_GROUP_NAME' erfolgreich erstellt."
    else
        error "Fehler beim Erstellen der Zugriffsgruppe."
        exit 1
    fi
}

# Admin-Richtlinien zur Gruppe hinzufügen
assign_admin_policies() {
    log "Weise Vollständige Administrator-Richtlinien zu..."
    
    # Alle Account Management Services - Administrator
    log "Erstelle Richtlinie für alle Account Management Services..."
    ibmcloud iam access-group-policy-create "$ACCESS_GROUP_NAME" \
        --roles Administrator \
        --account-management || warning "Account Management Richtlinie bereits vorhanden oder Fehler aufgetreten."
    
    # Alle IAM-enabled Services - Administrator
    log "Erstelle Richtlinie für alle IAM-enabled Services..."
    ibmcloud iam access-group-policy-create "$ACCESS_GROUP_NAME" \
        --roles Administrator \
        --service-name "*" || warning "IAM Services Richtlinie bereits vorhanden oder Fehler aufgetreten."
    
    # Spezifische Administrator-Rollen für kritische Services
    log "Erstelle spezifische Service-Richtlinien..."
    
    # IAM Identity Services
    ibmcloud iam access-group-policy-create "$ACCESS_GROUP_NAME" \
        --roles Administrator,Manager \
        --service-name iam-identity || warning "IAM Identity Richtlinie bereits vorhanden."
    
    # Resource Controller (für Ressourcengruppen)
    ibmcloud iam access-group-policy-create "$ACCESS_GROUP_NAME" \
        --roles Administrator \
        --service-name resource-controller || warning "Resource Controller Richtlinie bereits vorhanden."
    
    success "Administrator-Richtlinien erfolgreich zugewiesen."
}

# Benutzer einladen
invite_users() {
    log "Lade Benutzer aus der Datei '$EMAIL_FILE'..."
    
    local invited_count=0
    local failed_count=0
    
    while IFS= read -r email; do
        # Leere Zeilen und Kommentare überspringen
        if [[ -z "$email" || "$email" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        # E-Mail-Adresse bereinigen
        email=$(echo "$email" | xargs)
        
        log "Lade Benutzer ein: $email"
        
        # Benutzer einladen (falls noch nicht im Account)
        if ibmcloud account user-invite "$email" 2>/dev/null; then
            success "Benutzer $email erfolgreich eingeladen."
            ((invited_count++))
        else
            # Möglicherweise bereits im Account - trotzdem zur Gruppe hinzufügen
            warning "Benutzer $email konnte nicht eingeladen werden (möglicherweise bereits im Account)."
        fi
        
        # Kleine Pause zwischen Einladungen
        sleep 1
        
    done < "$EMAIL_FILE"
    
    log "Einladungsprozess abgeschlossen. $invited_count Benutzer eingeladen."
}

# Benutzer zur Zugriffsgruppe hinzufügen
add_users_to_group() {
    log "Füge Benutzer zur Zugriffsgruppe '$ACCESS_GROUP_NAME' hinzu..."
    
    local added_count=0
    local failed_count=0
    
    # Kurz warten, damit Einladungen verarbeitet werden können
    log "Warte 10 Sekunden auf Verarbeitung der Einladungen..."
    sleep 10
    
    while IFS= read -r email; do
        # Leere Zeilen und Kommentare überspringen
        if [[ -z "$email" || "$email" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        # E-Mail-Adresse bereinigen
        email=$(echo "$email" | xargs)
        
        log "Füge $email zur Zugriffsgruppe hinzu..."
        
        # Benutzer zur Gruppe hinzufügen
        if ibmcloud iam access-group-user-add "$ACCESS_GROUP_NAME" "$email" 2>/dev/null; then
            success "Benutzer $email erfolgreich zur Gruppe hinzugefügt."
            ((added_count++))
        else
            error "Fehler beim Hinzufügen von $email zur Gruppe."
            ((failed_count++))
        fi
        
        # Kleine Pause zwischen Operationen
        sleep 1
        
    done < "$EMAIL_FILE"
    
    log "Gruppenzuweisung abgeschlossen. $added_count Benutzer hinzugefügt, $failed_count Fehler."
}

# Zusammenfassung anzeigen
show_summary() {
    log "Zeige Zusammenfassung der Zugriffsgruppe..."
    
    echo -e "\n${BLUE}=== ZUGRIFFSGRUPPEN-ZUSAMMENFASSUNG ===${NC}"
    ibmcloud iam access-group "$ACCESS_GROUP_NAME"
    
    echo -e "\n${BLUE}=== GRUPPENMITGLIEDER ===${NC}"
    ibmcloud iam access-group-users "$ACCESS_GROUP_NAME"
    
    echo -e "\n${BLUE}=== GRUPPENRICHTLINIEN ===${NC}"
    ibmcloud iam access-group-policies "$ACCESS_GROUP_NAME"
}

# Bereinigungsfunktion für Fehlerbehandlung
cleanup() {
    if [[ $? -ne 0 ]]; then
        error "Script wurde aufgrund eines Fehlers beendet."
        echo "Überprüfen Sie die Logs und versuchen Sie es erneut."
    fi
}

# Hauptausführung
main() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║               IBM Cloud User Management Script               ║${NC}"
    echo -e "${BLUE}║                                                              ║${NC}"
    echo -e "${BLUE}║  Automatisierte Benutzereinladung und Gruppenverwaltung     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    
    trap cleanup EXIT
    
    check_prerequisites
    
    echo -e "\n${YELLOW}Warnung: Dieses Script wird eine Zugriffsgruppe mit VOLLSTÄNDIGEN${NC}"
    echo -e "${YELLOW}Administratorrechten erstellen und Benutzer hinzufügen.${NC}"
    echo -e "${YELLOW}Möchten Sie fortfahren? (j/N)${NC}"
    read -r response
    
    if [[ ! "$response" =~ ^[Jj]$ ]]; then
        log "Abbruch durch Benutzer."
        exit 0
    fi
    
    create_access_group
    assign_admin_policies
    invite_users
    add_users_to_group
    show_summary
    
    success "Script erfolgreich abgeschlossen!"
    echo -e "\n${GREEN}Alle Benutzer wurden eingeladen und der Admin-Zugriffsgruppe zugewiesen.${NC}"
}

# Script ausführen
main "$@"
