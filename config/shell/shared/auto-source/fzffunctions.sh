if command -v fd >/dev/null 2>&1; then
    export FZF_DEFAULT_COMMAND='fd --type f --type d'
fi
export FZF_DEFAULT_OPTS='-m --height 70% --reverse --border'

##TODO add -h -H like fcd
fzff() {
    fdoption="--type f"
    findoption="-type f -not -path '*/\.*'"
    while getopts ":hH" opt; do
        case "$opt" in
        h)
            cat <<-EOF
				Usage: $0 [Options] [path(default: \$HOME)]
				Options:
				-h              help
				-H              show hidden direcories
				EOF
            return 0
            ;;
        H)
            fdoption="-HI --type d"
            findoption="-type d"
            ;;
        esac
    done
    shift $((OPTIND - 1))

    local dest=${1:-$HOME}
    if [ -d "$dest" ]; then
        local wd=$(pwd)
        cd "$dest"
    else
        echo "No such directory: '$dest'"
        return 1
    fi

    eval "fd $fdoption" | fzf || {
        echo "canceld" >&2
        cd $wd
    }
}

##TODO add -h -H like fcd
fzfd() {
    local dest=${1:-$HOME}
    if [ -d "$dest" ]; then
        local wd=$(pwd)
        cd "$dest"
    else
        echo "No such directory: '$dest'"
        return 1
    fi

    fd --type d | fzf || {
        echo "canceld."
        cd $wd
    }
}

fp() {
    fzf --bind 'ctrl-f:preview-page-down' --bind 'ctrl-b:preview-page-up' --preview '[[ $(file --mime {}) =~ binary ]] && echo {} is a binary file || (bat --style=numbers --color=always {} || rougify {}  || highlight -O ansi -l {} || coderay {} || cat -n {}) 2> /dev/null | head -500'
}

fe() {
    fdoption="--type f"
    findoption="-type f -not -path '*/\.*'"
    while getopts ":hH" opt; do
        case "$opt" in
        h)
            cat <<-EOF
				Usage: $0 [Options] [path (default: \$HOME)]
				Options:
				-h          help
				-H          show hidden files
EOF
            return
            ;;
        H)
            fdoption="-HI --type f"
            findoption="-type f"
            ;;
        esac
    done
    shift $((OPTIND - 1))

    local dest=${1:-$HOME}
    if [ -d "$dest" ]; then
        local wd=$(pwd)
        cd "$dest"
    else
        echo "No such directory: '$dest'"
        return 1
    fi

    local editor=vi
    if command -v vim >/dev/null 2>&1; then
        editor=vim
    fi

    if command -v nvim >/dev/null 2>&1; then
        editor=nvim
    fi

    if command -v fd >/dev/null 2>&1; then
        file=$(eval "fd $fdoption" | fzf --border --height 60% --reverse -m --bind 'ctrl-f:preview-page-down' --bind 'ctrl-b:preview-page-up' --preview '[[ $(file --mime {}) =~ binary ]] && echo {} is a binary file || (bat --style=numbers --color=always {} || rougify {}  || highlight -O ansi -l {} || coderay {} || cat -n {}) 2> /dev/null | head -500')
    else
        file=$(eval "find . $findoption" | fzf --border --height 60% --reverse -m --bind 'ctrl-f:preview-page-down' --bind 'ctrl-b:preview-page-up' --preview '[[ $(file --mime {}) =~ binary ]] && echo {} is a binary file || (bat --style=numbers --color=always {} || rougify {}  || highlight -O ansi -l {} || coderay {} || cat -n {}) 2> /dev/null | head -500')
    fi
    if [ -n "$file" ]; then
        # multi files
        echo "$file" | tr '\n' ' ' | xargs $editor
    fi
    cd "$wd"
}

fcd() {
    fdoption="--type d"
    findoption="-type d -not -path '*/\.*'"
    while getopts ":hH" opt; do
        case "$opt" in
        h)
            cat <<-EOF
				Usage: $0 [Options] [path(default: \$HOME)]
				Options:
				-h              help
				-H              show hidden direcories
				EOF
            return 0
            ;;
        H)
            fdoption="-HI --type d"
            findoption="-type d"
            ;;
        esac
    done
    shift $((OPTIND - 1))

    local dest=${1:-$HOME}
    if [ -d "$dest" ]; then
        local wd=$(pwd)
        cd "$dest"
    else
        echo "No such directory: '$dest'"
        return 1
    fi

    local dir
    if command -v fd >/dev/null 2>&1; then
        dir=$(eval "fd ${fdoption}" | fzf --height 60% --border --reverse) && cd "$dir" || {
            echo "Canceled"
            cd "$wd"
        }
    else
        dir=$(eval "find . ${findoption}" | fzf --height 60% --border --reverse) && cd "$dir" || {
            echo "Canceled"
            cd "$wd"
        }
    fi
}

## deprecated
fCD() {
    local dest=${1:-$HOME}
    if [ -d "$dest" ]; then
        local wd=$(pwd)
        cd "$dest"
    else
        echo "No such directory: '$dest'"
        return 1
    fi

    local dir
    if command -v fd >/dev/null 2>&1; then
        dir=$(fd -HI --type d | fzf --height 80% --border --reverse) && cd "$dir" || {
            echo "Canceled"
            cd "$wd"
        }
    else
        dir=$(find . -type d | fzf --height 80% --border --reverse) && cd "$dir" || {
            echo "Canceled"
            cd "$wd"
        }
    fi
}
## deprecated
## deprecated
fE() {
    local dest=${1:-$HOME}
    if [ -d "$dest" ]; then
        local wd=$(pwd)
        cd "$dest"
    else
        echo "No such directory: '$dest'"
        return 1
    fi

    local editor=vi
    if command -v vim >/dev/null 2>&1; then
        editor=vim
    fi

    if command -v nvim >/dev/null 2>&1; then
        editor=nvim
    fi

    if command -v fd >/dev/null 2>&1; then
        file=$(fd -HI --type f | fzf --border --height 60% --reverse -m --bind 'ctrl-f:preview-page-down' --bind 'ctrl-b:preview-page-up' --preview '[[ $(file --mime {}) =~ binary ]] && echo {} is a binary file || (bat --style=numbers --color=always {} || rougify {}  || highlight -O ansi -l {} || coderay {} || cat -n {}) 2> /dev/null | head -500')
    else
        file=$(find . -type f | fzf --border --height 60% --reverse -m --bind 'ctrl-f:preview-page-down' --bind 'ctrl-b:preview-page-up' --preview '[[ $(file --mime {}) =~ binary ]] && echo {} is a binary file || (bat --style=numbers --color=always {} || rougify {}  || highlight -O ansi -l {} || coderay {} || cat -n {}) 2> /dev/null | head -500')
    fi
    if [ -n "$file" ]; then
        # multi files
        echo "$file" | tr '\n' ' ' | xargs $editor
    fi
    cd "$wd"
}
## deprecated
