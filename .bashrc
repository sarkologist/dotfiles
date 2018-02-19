ulimit -S -n 2048

alias g=git
alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'


export PATH=$HOME/.local/bin:$PATH

if which ruby >/dev/null && which gem >/dev/null; then
    PATH="$(ruby -rubygems -e 'puts Gem.user_dir')/bin:$PATH"
fi

[ -f ~/.fzf.bash ] && source ~/.fzf.bash
