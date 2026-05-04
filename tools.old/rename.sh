#######
# @file rename.sh
# @brief  批量修改某个路径下同一类型的文件名，按序号重命名
# @author 孙亮 email:sunliang711@gmail.com
# @version 1.0
# @date 2016-09-25
######
#!/bin/bash

if (( $# < 2 ));then
    echo "usage: ${0} <dest> <ext> [number]"
    exit 1
fi

#最少需要两个参数
#第1个参数是目标路径
#第2个参数是要修改的文件类型的扩展名
#第3个参数是新文件名中的起始序号,默认是1,可以省略
dst=${1}
ext=${2}
index=${3:-"1"}

#ext是第二个命令行参数，不知道是大写还是小写，
#所以先toupper()肯定转成大写，再用tolower()
#转成小写
EXT=$(echo ${ext}|awk '{print toupper($0)}')
ext=$(echo ${ext}|awk '{print tolower($0)}')

#for file in `ls ${dst}/*${ext} ${dst}/*${EXT} 2>/dev/null`;do
for file in ${dst}/*${ext} ${dst}/*${EXT} ;do
    newfile="img_${index}.${ext}"
    mv "$file" "$dst/$newfile"
    echo "$file --> $dst/$newfile"
    ((index++))
    # index=$(($index+1))
done
