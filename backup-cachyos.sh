#!/bin/bash
# Script de backup e restauração para CachyOS
# Uso: ./backup-cachyos.sh [backup|restore]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/cachyos-backup-$(date +%Y%m%d)"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1"; }

# Lista de diretórios e arquivos de configuração para backup
CONFIG_ITEMS=(
    ".config"                    # Configurações de apps modernos
    ".local/etc"               # Configurações locais
    ".local/share/applications" # .desktop files personalizados
    ".themes"
    ".icons"
    ".fonts"
    ".zshenv"
    ".zshrc"
    ".bashrc"
    ".bash_profile"
    ".bash_logout"
    ".profile"
    ".gtkrc-2.0"
    ".gitconfig"
    ".ssh"                     # Chaves SSH (atenção: sensível!)
    ".gnupg"                   # Chaves GPG (atenção: sensível!)
    ".pki"
    ".npmrc"
    ".npm"
    ".nvm"
    ".pyenv"
    ".rbenv"
    ".go"
    ".cargo"
    ".rustup"
    ".bun"
    ".volta"
    ".config/Code"             # VS Code settings
    ".config/vscode"
    ".config/cursor"
    ".var"                     # Flatpak app data
)

# Diretórios de configuração do sistema (precisa de sudo)
SYSTEM_CONFIGS=(
    "/etc/pacman.conf"
    "/etc/pacman.d"
    "/etc/makepkg.conf"
    "/etc/mkinitcpio.conf"
    "/etc/fstab"
    "/etc/crypttab"
    "/etc/hosts"
    "/etc/hostname"
    "/etc/locale.conf"
    "/etc/locale.gen"
    "/etc/vconsole.conf"
    "/etc/timezone"
    "/etc/modprobe.d"
    "/etc/modules-load.d"
    "/etc/udev/rules.d"
    "/etc/sysctl.d"
    "/etc/systemd"
    "/etc/X11"
    "/etc/default"
    "/etc/sudoers.d"
    "/etc/polkit-1"
    "/etc/NetworkManager"
    "/etc/resolv.conf"
)

do_backup() {
    info "Iniciando backup do CachyOS..."

    mkdir -p "$BACKUP_DIR"
    cd "$BACKUP_DIR"

    # Criar estrutura de diretórios
    mkdir -p home system packages services

    info "Salvando lista de pacotes instalados..."

    # Pacotes oficiais
    pacman -Qqen > packages/pacman-packages.txt 2>/dev/null || true

    # Pacotes AUR/externos
    pacman -Qqem > packages/foreign-packages.txt 2>/dev/null || true

    # Lista completa com versões
    pacman -Q > packages/all-packages-with-versions.txt 2>/dev/null || true

    # Pacotes explicitamente instalados (não dependências)
    pacman -Qqe > packages/explicit-packages.txt 2>/dev/null || true

    # Snapshots se existirem
    if command -v snapper &> /dev/null; then
        snapper list > packages/snapper-snapshots.txt 2>/dev/null || true
    fi

    # Flatpaks
    if command -v flatpak &> /dev/null; then
        flatpak list --app > packages/flatpak-apps.txt 2>/dev/null || true
        flatpak list --runtime > packages/flatpak-runtimes.txt 2>/dev/null || true
        flatpak remotes > packages/flatpak-remotes.txt 2>/dev/null || true
    fi

    info "Backup de configurações do usuário..."

    # Backup das configs do usuário
    for item in "${CONFIG_ITEMS[@]}"; do
        if [[ -e "$HOME/$item" ]]; then
            target_dir="home/$(dirname "$item")"
            mkdir -p "$target_dir"
            cp -aL "$HOME/$item" "$target_dir/" 2>/dev/null && info "Copiado: $item" || warn "Não foi possível copiar: $item"
        fi
    done

    info "Backup de configurações do sistema (pode pedir senha)..."

    # Backup de configs do sistema
    for item in "${SYSTEM_CONFIGS[@]}"; do
        if [[ -e "$item" ]]; then
            target_path="system$item"
            mkdir -p "$(dirname "$target_path")"
            if [[ -d "$item" ]]; then
                sudo cp -aL "$item" "$target_path" 2>/dev/null && info "Copiado: $item" || warn "Não foi possível copiar: $item"
            else
                sudo cp -aL "$item" "$target_path" 2>/dev/null && info "Copiado: $item" || warn "Não foi possível copiar: $item"
            fi
        fi
    done

    info "Salvando informações de serviços..."

    # Serviços habilitados
    systemctl list-unit-files --state=enabled --type=service > services/enabled-services.txt 2>/dev/null || true

    # Serviços do usuário habilitados
    systemctl --user list-unit-files --state=enabled --type=service > services/user-enabled-services.txt 2>/dev/null || true

    # Timers habilitados
    systemctl list-unit-files --state=enabled --type=timer > services/enabled-timers.txt 2>/dev/null || true

    info "Salvando informações de hardware e kernel..."

    # Kernel e drivers
    uname -r > system/kernel-version.txt
    ls /boot > system/boot-files.txt 2>/dev/null || true
    lsmod > system/loaded-modules.txt 2>/dev/null || true

    # Informações de partições
    lsblk -f > system/lsblk.txt 2>/dev/null || true
    blkid > system/blkid.txt 2>/dev/null || true

    # Configurações de bootloader
    if [[ -d "/boot/loader" ]]; then
        cp -r /boot/loader system/ 2>/dev/null || true
    fi
    if [[ -d "/boot/grub" ]]; then
        sudo cp -r /boot/grub system/ 2>/dev/null || true
    fi

    # CachyOS específico
    if [[ -f "/etc/cachyos-release" ]]; then
        cat /etc/cachyos-release > system/cachyos-release.txt
    fi

    info "Salvando aliases e funções do shell..."

    # Aliases e funções do zsh
    if [[ -f "$HOME/.zshrc" ]]; then
        grep -E "^(alias|function)" "$HOME/.zshrc" > home/.zsh_aliases.txt 2>/dev/null || true
    fi

    # Aliases e funções do bash
    if [[ -f "$HOME/.bashrc" ]]; then
        grep -E "^(alias|function)" "$HOME/.bashrc" > home/.bash_aliases.txt 2>/dev/null || true
    fi

    info "Gerando script de restauração..."

    cat > restore.sh << 'RESTORE_SCRIPT'
#!/bin/bash
# Script de restauração gerado automaticamente

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1"; }

info "Script de restauração do CachyOS"
echo ""
echo "ATENÇÃO: Execute este script APÓS instalar o CachyOS base"
echo "e configurar o usuário com o mesmo nome de usuário."
echo ""
read -p "Continuar? (s/N): " confirm
if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
    exit 0
fi

cd "$SCRIPT_DIR"

# Verificar se estamos no CachyOS
if [[ ! -f "/etc/arch-release" ]] && [[ ! -f "/etc/cachyos-release" ]]; then
    error "Este script deve ser executado no CachyOS/Arch Linux"
    exit 1
fi

info "Adicionando repositórios CachyOS..."
# O CachyOS já deve ter os repos, mas garantimos
if ! grep -q "cachyos" /etc/pacman.conf 2>/dev/null; then
    warn "Repositórios CachyOS não encontrados. Verifique a instalação base."
fi

info "Instalando pacotes..."

# Instalar pacotes oficiais
if [[ -f "packages/pacman-packages.txt" ]]; then
    info "Instalando pacotes do repositório oficial..."
    sudo pacman -Syu --needed - < packages/pacman-packages.txt || warn "Alguns pacotes podem não estar disponíveis"
fi

# Verificar se yay ou paru está instalado
if ! command -v yay &> /dev/null && ! command -v paru &> /dev/null; then
    warn "AUR helper não encontrado. Instalando yay..."
    sudo pacman -S --needed git base-devel
    git clone https://aur.archlinux.org/yay.git /tmp/yay
    cd /tmp/yay
    makepkg -si --noconfirm
    cd "$SCRIPT_DIR"
fi

# Instalar pacotes AUR
if [[ -f "packages/foreign-packages.txt" ]]; then
    info "Instalando pacotes AUR..."
    AUR_HELPER="yay"
    command -v yay &> /dev/null || AUR_HELPER="paru"

    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && $AUR_HELPER -S --needed --noconfirm "$pkg" || true
    done < packages/foreign-packages.txt
fi

# Restaurar Flatpaks
if [[ -f "packages/flatpak-apps.txt" ]] && command -v flatpak &> /dev/null; then
    info "Restaurando Flatpaks..."
    # Adicionar remotes primeiro
    if [[ -f "packages/flatpak-remotes.txt" ]]; then
        while IFS=$'\t' read -r name url options; do
            [[ -n "$name" && -n "$url" ]] && flatpak remote-add --if-not-exists "$name" "$url" 2>/dev/null || true
        done < packages/flatpak-remotes.txt
    fi

    # Instalar apps
    while IFS=$'\t' read -r name app_id version branch origin installation; do
        if [[ -n "$app_id" && ! "$app_id" =~ ^Application ]]; then
            flatpak install -y --noninteractive "$origin" "$app_id" 2>/dev/null || warn "Não foi possível instalar: $app_id"
        fi
    done < packages/flatpak-apps.txt
fi

info "Restaurando configurações do sistema..."

# Criar backup das configs atuais do sistema
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
sudo mkdir -p "/etc/backup-system-$BACKUP_TIMESTAMP"

# Restaurar configs do sistema
if [[ -d "system/etc" ]]; then
    for item in system/etc/*; do
        if [[ -e "$item" ]]; then
            target="/etc/$(basename "$item")"
            if [[ -e "$target" ]]; then
                sudo cp -a "$target" "/etc/backup-system-$BACKUP_TIMESTAMP/" 2>/dev/null || true
            fi
            if [[ -d "$item" ]]; then
                sudo cp -a "$item"/* "$target/" 2>/dev/null || warn "Não foi possível restaurar: $target"
            else
                sudo cp -a "$item" "$target" 2>/dev/null || warn "Não foi possível restaurar: $target"
            fi
            info "Restaurado: $target"
        fi
    done
fi

info "Restaurando configurações do usuário..."

# Criar backup das configs atuais do usuário
mkdir -p "$HOME/backup-home-$BACKUP_TIMESTAMP"

# Restaurar configs do usuário
if [[ -d "home" ]]; then
    for item in home/.* home/*; do
        if [[ -e "$item" ]]; then
            target_name=$(basename "$item")
            # Pular . e ..
            [[ "$target_name" == "." || "$target_name" == ".." ]] && continue

            target="$HOME/$target_name"

            # Fazer backup do atual
            if [[ -e "$target" ]]; then
                cp -a "$target" "$HOME/backup-home-$BACKUP_TIMESTAMP/" 2>/dev/null || true
            fi

            # Restaurar
            rm -rf "$target" 2>/dev/null || true
            cp -a "$item" "$target" 2>/dev/null && info "Restaurado: $target" || warn "Não foi possível restaurar: $target"
        fi
    done
fi

info "Restaurando serviços habilitados..."

# Restaurar serviços do sistema
if [[ -f "services/enabled-services.txt" ]]; then
    while IFS=" " read -r service state; do
        if [[ -n "$service" && ! "$service" =~ ^UNIT && ! "$service" =~ ^Legend ]]; then
            sudo systemctl enable "$service" 2>/dev/null || warn "Não foi possível habilitar: $service"
        fi
    done < services/enabled-services.txt
fi

# Restaurar timers
if [[ -f "services/enabled-timers.txt" ]]; then
    while IFS=" " read -r timer state; do
        if [[ -n "$timer" && ! "$timer" =~ ^UNIT && ! "$timer" =~ ^Legend ]]; then
            sudo systemctl enable "$timer" 2>/dev/null || warn "Não foi possível habilitar: $timer"
        fi
    done < services/enabled-timers.txt
fi

info "Recriando links simbólicos de algumas configs..."

# Alguns programas precisam de recriação de links
# VS Code/Codium
if [[ -d "$HOME/.config/Code" ]] || [[ -d "$HOME/.config/VSCodium" ]]; then
    info "Configurações do VS Code restauradas"
fi

info "Atualizando caches..."

# Atualizar cache de fontes
if command -v fc-cache &> /dev/null; then
    fc-cache -fv 2>/dev/null || true
fi

# Atualizar cache de icones
gtk-update-icon-cache -f -t "$HOME/.icons" 2>/dev/null || true

info "Restauração concluída!"
info "Reinicie o sistema para aplicar todas as mudanças."
info ""
info "Configs antigas salvas em:"
info "  - Sistema: /etc/backup-system-$BACKUP_TIMESTAMP"
info "  - Usuário: $HOME/backup-home-$BACKUP_TIMESTAMP"
RESTORE_SCRIPT

    chmod +x restore.sh

    # Criar README
    cat > README.md << EOF
# Backup do CachyOS - $(date +%Y-%m-%d)

## Estrutura

- \`home/\` - Configurações do usuário (~)
- \`system/\` - Configurações do sistema (/etc)
- \`packages/\` - Listas de pacotes instalados
- \`services/\` - Serviços habilitados
- \`restore.sh\` - Script de restauração automática

## Como Restaurar

1. Instale o CachyOS normalmente
2. Crie seu usuário com o mesmo nome
3. Instale o yay (AUR helper):
   \`\`\`bash
   sudo pacman -S --needed git base-devel
   git clone https://aur.archlinux.org/yay.git
   cd yay && makepkg -si
   \`\`\`
4. Execute o script de restauração:
   \`\`\`bash
   cd cachyos-backup-*/
   ./restore.sh
   \`\`\`

## Pacotes Principais

### Pacotes Oficiais
\`\`\`
$(wc -l < packages/pacman-packages.txt 2>/dev/null || echo "0") pacotes
\`\`\`

### Pacotes AUR
\`\`\`
$(wc -l < packages/foreign-packages.txt 2>/dev/null || echo "0") pacotes
\`\`\`

### Flatpaks
\`\`\`
$(wc -l < packages/flatpak-apps.txt 2>/dev/null || echo "0") apps
\`\`\`

## Notas

- Chaves SSH e GPG foram incluídas (diretório \`home/.ssh/\` e \`home/.gnupg/\`)
- Senhas não são transferidas - reconfigure manualmente em apps que precisam
- Verifique permissões após restaurar
EOF

    # Criar tarball compactado
    info "Criando arquivo compactado..."
    cd "$SCRIPT_DIR"
    tar czf "${BACKUP_DIR##*/}.tar.gz" "${BACKUP_DIR##*/}"

    info "Backup concluído!"
    info "Local: $BACKUP_DIR"
    info "Arquivo: ${BACKUP_DIR##*/}.tar.gz"
    info ""
    info "Copie o arquivo tar.gz para um pendrive/nuvem antes de reinstalar."
}

do_restore() {
    if [[ -f "restore.sh" ]]; then
        ./restore.sh
    else
        error "Script de restauração não encontrado no diretório atual"
        error "Execute este script no diretório do backup"
        exit 1
    fi
}

# Menu principal
case "${1:-backup}" in
    backup)
        do_backup
        ;;
    restore)
        do_restore
        ;;
    *)
        echo "Uso: $0 [backup|restore]"
        echo ""
        echo "  backup  - Criar backup (padrão)"
        echo "  restore - Restaurar a partir do backup"
        exit 1
        ;;
esac
