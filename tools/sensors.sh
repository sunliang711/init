#!/bin/bash

if ! command -v sensors >/dev/null 2>&1;then
	apt update
	apt install lm-sensors -y
fi

nodesFile="/usr/share/perl5/PVE/API2/Nodes.pm"

if [ ! -e ${nodesFile}.orig ];then
	cp ${nodesFile}{,.orig}
fi
cp ${nodesFile}{,.bak}

if ! grep -q '$res->{thermalstate}' ${nodesFile};then
sed -i '/version_text()/a \
\
	$res->{thermalstate} = `sensors`;' ${nodesFile}
fi

pveManagerLibs="/usr/share/pve-manager/js/pvemanagerlib.js"

if [ ! -e ${pveManagerLibs}.orig ];then
	cp ${pveManagerLibs}{,.orig}
fi
cp ${pveManagerLibs}{,.bak}

sed -i.bak -e "/show_detail: function/,/title: gettext('Status')/{
s/height: 400/height: 420/
}" -e "/PVE.node.StatusView/,/height:/{
s/height: 300/height: 320/
}" ${pveManagerLibs}


if grep -q 'Thermal State' ${pveManagerLibs};then
	echo "exist Thermal State,exit"
	exit 0
fi
cat<<EOF>xx
},
{
	itemId: 'thermal',
	colspan: 2,
	printBar: false,
	title: gettext('Thermal State'),
	textField: 'thermalstate',
	renderer:function(value){
		const p0 = value.match(/Package id 0.*?\+([\d\.]+)?/)[1];
EOF


cpuCoreNum=$(grep -c 'processor' /proc/cpuinfo)
for ((i=0;i<$cpuCoreNum;i++)){

	${xx}cat<<EOF>>xx
	const c${i} = value.match(/Core ${i}.*?\+([\d\.]+)?/)[1];
EOF
}

for ((i=0;i<$cpuCoreNum;i++)){
	cores="$cores $(cat<<EOF
\${c${i}} |
EOF
)"
}

cat<<EOF>>xx
	return \`Package: \${p0} | Core:$cores\`
}
EOF

content="$(cat xx)"


sed -n -e "1,/title: gettext('PVE Manager Version')/p" ${pveManagerLibs} > header

sed -n -e "/title: gettext('PVE Manager Version')/,/value:/p" ${pveManagerLibs} >header2
sed -n -e '2,$p' header2>>header
sed -n -e "/title: gettext('PVE Manager Version')/,/sunliang/p" ${pveManagerLibs} >tail
sed -n -e '4,$p' tail>tail2

cat header xx tail2 >${pveManagerLibs}

rm header header2 tail tail2 xx

systemctl restart pveproxy



