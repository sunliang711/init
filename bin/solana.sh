#!/bin/bash
if [ -z "${BASH_SOURCE}" ]; then
    this=${PWD}
else
    rpath="$(readlink ${BASH_SOURCE})"
    if [ -z "$rpath" ]; then
        rpath=${BASH_SOURCE}
    elif echo "$rpath" | grep -q '^/'; then
        # absolute path
        echo
    else
        # relative path
        rpath="$(dirname ${BASH_SOURCE})/$rpath"
    fi
    this="$(cd $(dirname $rpath) && pwd)"
fi

if [ -r ${SHELLRC_ROOT}/shelllib ]; then
    source ${SHELLRC_ROOT}/shelllib
elif [ -r /tmp/shelllib ]; then
    source /tmp/shelllib
else
    # download shelllib then source
    shelllibURL=https://gitee.com/sunliang711/init2/raw/master/shell/shellrc.d/shelllib
    (cd /tmp && curl -s -LO ${shelllibURL})
    if [ -r /tmp/shelllib ]; then
        source /tmp/shelllib
    fi
fi

# available VARs: user, home, rootID
# available functions:
#    _err(): print "$*" to stderror
#    _command_exists(): check command "$1" existence
#    _require_command(): exit when command "$1" not exist
#    _runAsRoot():
#                  -x (trace)
#                  -s (run in subshell)
#                  --nostdout (discard stdout)
#                  --nostderr (discard stderr)
#    _insert_path(): insert "$1" to PATH
#    _run():
#                  -x (trace)
#                  -s (run in subshell)
#                  --nostdout (discard stdout)
#                  --nostderr (discard stderr)
#    _ensureDir(): mkdir if $@ not exist
#    _root(): check if it is run as root
#    _require_root(): exit when not run as root
#    _linux(): check if it is on Linux
#    _require_linux(): exit when not on Linux
#    _wait(): wait $i seconds in script
#    _must_ok(): exit when $? not zero
#    _info(): info log
#    _infoln(): info log with \n
#    _error(): error log
#    _errorln(): error log with \n
#    _checkService(): check $1 exist in systemd

###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'
solanaRoot=~/.config/solana
explorBaseUrl="https://solscan.io"

installcli() {
    # install solana cli
    local version=${version:-1.17.13}
    set -xe
    sh -c "$(curl -sSfL https://release.solana.com/v${version}/install)"
    solana-install update
    # install spl-token
    cargo install spl-token-cli
}

###  network manager
devnet() {
    set -xe
    solana config set --url devnet
}

testnet() {
    set -xe
    solana config set --url testnet
}

mainnet() {
    set -xe
    solana config set --url mainnet-beta #https://api.mainnet-beta.solana.com
}

_currentNetwork(){
    rpc="$(solana config get | grep 'RPC')"
    network="$(echo $rpc | perl -lne 'print $1 if /api.(\w+)/')"
    echo "$network"

}

network() {
    echo "Current network: $(_currentNetwork)"

}
###  network manager

_txUrl(){
    txHash=${1:?'missing tx hash'}
    currentNetwork="$(_currentNetwork)"

    fullUrl="${explorBaseUrl}/tx/${txHash}"
    # 主网不需要?cluster=xxx
    if [ "${currentNetwork}" != "mainnet" ];then
        fullUrl="${fullUrl}?cluster=${currentNetwork}"
    fi
    echo -n "$fullUrl"
}

_accountUrl(){
    address=${1:?'missing account address'}
    currentNetwork="$(_currentNetwork)"

    fullUrl="${explorBaseUrl}/account/${address}"
    # 主网不需要?cluster=xxx
    if [ "${currentNetwork}" != "mainnet" ];then
        fullUrl="${fullUrl}?cluster=${currentNetwork}"
    fi
    echo -n "$fullUrl"
}

### account
newAccount() {
    # create system account
    local account=${1:?'missing account name'}
    cd ${solanaRoot}

    [ -e ${account}.json ] && {
        echo "already exists such account(${solanaRoot}/${account}.json)"
        return 1
    }

    solana-keygen new -o ${account}.json
}

ledger(){
    solana config set --keypair usb://ledger/
}

accounts(){
    ls ${solanaRoot}/*.json
}

defaultKeypair(){
    account=${1:?'missing account name'}
    solana config set --keypair "${solanaRoot}/${account}.json"
}

_address(){
    account=${1:?'missing account name'}
    solana address -k "${solanaRoot}/${account}.json"
}

_balance(){
    account=${1:?'missing account name'}
    solana balance "${solanaRoot}/${account}.json"
}

accountInfo(){
    account=${1:?'missing account name'}
    network
    address="$(_address ${account})"
    url="$(_accountUrl ${address})"
    balance="$(_balance ${account})"

    cat<<EOF
Address: ${address}
Solscan URL: ${url}
Balance: ${balance}
EOF
}

airdrop() {
    amount=${1:?'missing amount'}
    receiver=${2:?'missing receiver name'}

    cd ${solanaRoot}
    [ ! -e ${receiver}.json ] && {
        echo "no such account"
        return 1
    }
    network
    solana airdrop $amount ${receiver}.json
}

##--------------------------------------------------------------------

newToken() {
    cd ${solanaRoot}
    mintAuth=${1:?'missing mint auth account name'}
    feePayer=${2:?'missing fee payer account name'}
    decimals=${3:-9}

    network
    mintAuthAddress="$(solana address -k ${mintAuth}.json)"
    feePayerAddress="$(solana address -k ${feePayer}.json)"

    cat <<-EOF
	create new nft(mint account) with the following info:
	    mintAuth: ${mintAuthAddress}
	    feePayer: ${feePayerAddress}
	    decimals: ${decimals}
	EOF

    spl-token create-token --mint-authority ${mintAuth}.json \
        --fee-payer ${feePayer}.json \
        --decimals ${decimals}
}

tokenSupply() {
    cd ${solanaRoot}
    nft=${1:?'missing nft address'}
    spl-token supply $nft
}

newTokenAccount() {
    cd ${solanaRoot}

    owner=${1:?'mssing account owner(system account) name'}
    feePayer=${2:?'missing feepayer account name'}
    nftAddress=${3:?'missing nft address'}

    spl-token create-account \
        --owner ${owner}.json \
        --fee-payer ${feePayer}.json \
        ${nftAddress}
}

getTokenAccount(){
    ataPubkey=ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL
    tokenPubkey=TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA
    walletPubkey=${1:?'missing wallet account pubkey'}
    mintPubkey=${2:?'missing mint account pubkey'}

    solana find-program-derived-address "${ataPubkey}" pubkey:${walletPubkey} pubkey:${tokenPubkey} pubkey:${mintPubkey}
}

tokenAccountInfo() {
    tokenAccount=${1:?'missing token account'}
    spl-token account-info --address "${tokenAccount}"
}

mintToken() {
    cd ${solanaRoot}

    mintAuth=${1:?'missing mint auth account name'}
    feePayer=${2:?'missing fee payer account name'}
    nftAddress=${3:?'missing nft address'}
    amount=${4:?'missing amount'}
    receiver=${5:?'missing receiver account name'}

    tokenAccount="$(spl-token create-account --owner ${receiver}.json --fee-payer ${feePayer}.json ${nftAddress} 2>/dev/null | perl -lne 'print $1 if /Creating account (.+)/')"
    mintAuthAddress="$(solana address -k ${mintAuth}.json)"
    feePayerAddress="$(solana address -k ${feePayer}.json)"

    cat <<-EOF
	mint nft with the following info:
	    mintAuth: ${mintAuthAddress}
	    feePayer: ${feePayerAddress}
	tokenAccount: ${tokenAccount}
	EOF

    set -x
    spl-token mint ${nftAddress} ${amount} ${tokenAccount} \
        --fee-payer ${feePayer}.json \
        --mint-authority ${mintAuth}.json
}

burnToken() {
    cd ${solanaRoot}
    tokenAccount=${1:?'missing token account address'}
    amount=${2:?'missing amount'}
    feePayer=${3:?'missing feePayer'}
    owner=${4:?'missing owner'}

    spl-token burn ${tokenAccount} ${amount} --fee-payer ${feePayer}.json --owner ${owner}.json

}

# write your code above
###############################################################################

em() {
    $ed $0
}

function _help() {
    cd "${this}"
    cat <<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\S+)\s*\(\)\s*\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

case "$1" in
"" | -h | --help | help)
    _help
    ;;
*)
    "$@"
    ;;
esac
