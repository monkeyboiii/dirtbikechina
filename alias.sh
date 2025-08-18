######### add this to ~/.bashrc #########
# if [ -f ~/dirtbikechina/alias.sh ]; then
#   source alias.sh
# fi
########################################

alias sdp='sudo docker ps'
alias sdpa='sudo docker ps -a'
alias sdc='sudo docker compose'
alias sdeit='sudo docker exec -it'
alias sdcpd='sudo docker compose -p dirtbikechina'
alias sdcpdf='sudo docker compose -p dirtbikechina -f compose.edge.yml -f compose.infra.yml -f compose.apps.yml'

sdcid() {
  if [ -z "$1" ]; then
    echo "Usage: sdcid <service_name>"
    return 1
  fi

  sdcpdf ps -a -q "$1"
}

sdcex() {
  if [ -z "$1" ]; then
    echo "Usage: sdep <service_name> [command]"
    return 1
  fi
  
  local container_id=$(sdcid "$1")
  
  if [ -z "$container_id" ]; then
    echo "Service '$1' not found or not running"
    return 1
  fi
  
  sdeit "$container_id" "${2:-/bin/bash}"
}

eased() {
    if [ -z "$1" ]; then
        echo "Usage: eased <alias_name>"
        return 1
    fi
    alias $1 | sed "s/alias $1='\(.*\)'/\1/"
}
