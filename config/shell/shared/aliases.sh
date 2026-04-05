alias cl='clear'
alias prettyjson='python -m json.tool'

# alias pushall='git remote | xargs -L1 -t -IR git push R'
# alias fetchall='git remote | xargs -L1 -t -IR git fetch R'

if command -v proxychains >/dev/null 2>&1; then
    alias pc='proxychains'
elif command -v proxychains4 >/dev/null 2>&1; then
    alias pc='proxychains4'
elif command -v proxychains5 >/dev/null 2>&1; then
    alias pc='proxychains5'
fi

alias lg='lazygit'

if command -v fdfind >/dev/null 2>&1; then
    alias fd='fdfind'
fi

alias dcp='docker compose'

case $(uname) in
"Linux")
    alias lA='ls -aF --color=auto'
    alias la='ls -AF --color=auto'
    alias ll='ls -lF --color=auto'
    alias l='ls -F --color=auto'
    alias ls='ls -F --color=auto'
    alias psaux='ps ax ouser,uid,group,gid,pid,ppid,%cpu,%mem,tty,stat,start,time,comm,args=ARGS'
    ;;
"Darwin")
    alias lA='ls -aFG'
    alias la='ls -AFG'
    alias ll='ls -lFG'
    #alias l='ls -FG'
    #alias ls='ls -FG'
    alias l='ls -G'
    alias ls='ls -G'
    alias psaux='ps -A -o user,uid,group,gid,pid,ppid,%cpu,%mem,tty,stat,start,time,comm,args=ARGS'
    #brew with local proxy
    # alias brewlp='echo "Using socks5 proxy: ALL_PROXY=socks5://localhost:1080"&&ALL_PROXY=socks5://localhost:1080 brew'
    # export PATH=/usr/local/Cellar/privoxy/3.0.26/sbin:$PATH
    ;;
esac
alias cd..='cd ..'
alias cd-='cd -'
alias grep='grep --color=auto'
alias jnc='sudo journalctl'
alias stc='sudo systemctl'

if command -v emacs >/dev/null 2>&1; then
    alias emacs='emacs -nw'
fi

if command -v free >/dev/null 2>&1; then
    if command -v pacman >/dev/null 2>&1; then
        alias free='free -hw'
    else
        alias free='free -h'
    fi
fi

alias tree='tree -I node_modules'
alias tree2='tree -L 2 -I node_modules'
alias tree3='tree -L 3 -I node_modules'

#用法:在echo中使用$(RED)some-text-to-be-color-red$(CLEAR)
# alias RED='tput setaf 1'
# alias CLEAR='tput sgr0'

# vim: set ft=sh:
