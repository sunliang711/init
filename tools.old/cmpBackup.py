#!/usr/bin/env python3

import os
import sys
import shutil
def usage():
    print("Usage: ",os.path.basename(sys.argv[0]), " src dst [blacklist]")
    sys.exit(1)

def checkDir(dirname):
    if not os.path.isdir(dirname):
        print("directory: ",dirname," does not exist!")
        sys.exit(1)

def cmpBackup(src,dst,blacklist):
    srcItems = os.listdir(src)
    #把群晖中的特殊文件夹@eaDir排除,以及mac os的.DS_Store
    srcItems = [os.sep.join(list((src,item))) for item in srcItems if item not in blacklist]
    #use the next??[TODO] 使用的时候测试一下
    #dstItems也一样
    #srcItems = [os.path.realpath(f) for f in os.listdir(src)]
    # print("srcItems:",srcItems)
    srcFiles = [item for item in srcItems if not os.path.isdir(item)]
    # print("srcFiles:",srcFiles)
    srcDirs = [item for item in srcItems if os.path.isdir(item)]
    # print("srcDirs:",srcDirs)

    dstItems = os.listdir(dst)
    dstItems = [os.sep.join(list((dst,item))) for item in dstItems]
    # print("dstItems:",dstItems)
    dstFiles = [item for item in dstItems if not os.path.isdir(item)]
    # print("dstFiles:",dstFiles)
    dstDirs = [item for item in dstItems if os.path.isdir(item)]
    # print("dstDirs:",dstDirs)

    for eachFile in srcFiles:
        basename = os.path.basename(eachFile)
        #如果文件已经存在并且比src中的新的时候,则什么都不做
        #否则(也就是文件不存在或者文件比src中的文件旧的时候,则复制)
        dstfilename = os.sep.join(list((dst,basename)))
        mtimeSrc = int(os.path.getmtime(eachFile))
        mtimeDst = 0
        if dstfilename in dstFiles:
            mtimeDst = int(os.path.getmtime(dstfilename))
            if mtimeSrc <= mtimeDst:
                continue

        print("**" + eachFile + ": " + str(mtimeSrc))
        print("##" + dstfilename + ": " + str(mtimeDst))
        print(">> copy2 " + eachFile+" --> " + dst)
        shutil.copy2(eachFile,dst)

    for eachDir in srcDirs:
        basename = os.path.basename(eachDir)
        dstdirname = os.sep.join(list((dst,basename)))
        # print('basename: ',basename)
        if dstdirname not in dstDirs:
            print("> copytree " + eachDir+" --> " + dstdirname)
            shutil.copytree(eachDir,dstdirname)
        else:
            cmpBackup(eachDir,dstdirname,blacklist)



def main():
    if len(sys.argv) < 3:
        usage()
    src = sys.argv[1]
    dst = sys.argv[2]
    blacklist=sys.argv[3:]

    #check src exists,dst exists
    checkDir(src)
    checkDir(dst)

    cmpBackup(src,dst,blacklist)

if __name__ == '__main__':
    main()
