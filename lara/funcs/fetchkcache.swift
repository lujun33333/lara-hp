//
//  fetchkcache.swift
//  lara
//
//  Created by ruter on 12.05.26.
//

import Foundation

func syskcpath() -> String? {
    guard let hash = getbmhash() else { return nil }
    return "/private/preboot/\(hash)/System/Library/Caches/com.apple.kernelcaches/kernelcache"
}

func larakcpath() -> String? {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
    return docs.appendingPathComponent("kernelcache").path
}

func fetchkcache(action requestedAction: CoreSetLocalHomeAction? = nil) -> Bool {
    let action = requestedAction ?? CoreSetLocalHomeAction()
    guard ds_is_ready(),
          ds_get_our_proc() != 0,
          ds_get_our_task() != 0,
          off_proc_p_fd != 0,
          off_filedesc_fd_ofiles != 0,
          off_fileproc_fp_glob != 0,
          off_fileglob_fg_data != 0,
          off_vnode_v_data != 0,
          off_namecache_nc_vp != 0,
          off_namecache_nc_child_tqe_next != 0 else {
        globallogger.log("(fetchkcache) 漏洞利用、自身进程/任务或偏移量未就绪")
        return false
    }

    guard let kcpath = syskcpath() else {
        globallogger.log("(fetchkcache) 无法获取内核缓存路径")
        return false
    }

    guard let outpath = larakcpath() else {
        globallogger.log("(fetchkcache) 无法获取输出路径")
        return false
    }

    let fakeread = "/private/preboot/Cryptexes/OS/System/Library/CoreServices/RestoreVersion.plist"

    unlink(outpath)

    var ogvn: UInt64 = 0
    var ogvd: UInt64 = 0

    let redirect = kcpath.withCString { kcCString in
        vn_fileredirect(fakeread, kcCString, &ogvn, &ogvd)
    }
    if !redirect {
        globallogger.log("(fetchkcache) 重定向 vnode 失败")
        return false
    }

    let src = open(fakeread, O_RDONLY)
    if src < 0 {
        vn_fileunredirect(ogvn, ogvd)
        return false
    }

    let dst = open(outpath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if dst < 0 {
        close(src)
        vn_fileunredirect(ogvn, ogvd)
        return false
    }

    var sourceStat = stat()
    guard fstat(src, &sourceStat) == 0, sourceStat.st_size > 0 else {
        close(src)
        close(dst)
        vn_fileunredirect(ogvn, ogvd)
        globallogger.log("(fetchkcache) 无法取得内核缓存总字节数")
        return false
    }
    let expectedBytes = UInt64(sourceStat.st_size)
    let transferOwner = CoreSetKernelCacheTransferOwner.shared
    transferOwner.begin(totalBytes: expectedBytes, action: action)
    var transferCompleted = false

    defer {
        if !transferCompleted {
            if action.isCancellationRequested {
                unlink(outpath)
                transferOwner.stoppedAfterCancellation(action: action)
            } else {
                transferOwner.fail(code: -1, message: "本机 kernelcache 复制未完成", action: action)
            }
        }
        close(src)
        close(dst)
        vn_fileunredirect(ogvn, ogvd)
    }

    var buffer = [UInt8](repeating: 0, count: 0x4000)
    let bufferSize = buffer.count
    var totalBytes = 0

    while true {
        if action.isCancellationRequested { return false }
        let n = buffer.withUnsafeMutableBytes { rawBuffer in
            read(src, rawBuffer.baseAddress!, bufferSize)
        }

        if n < 0 {
            globallogger.log("(fetchkcache) 读取内核缓存失败")
            return false
        }

        if n == 0 {
            break
        }

        var written = 0
        while written < n {
            if action.isCancellationRequested { return false }
            let w = buffer.withUnsafeBytes { rawBuffer in
                write(dst, rawBuffer.baseAddress!.advanced(by: written), n - written)
            }

            if w <= 0 {
                globallogger.log("(fetchkcache) 写入内核缓存失败")
                return false
            }

            written += w
            transferOwner.advance(downloadedBytes: UInt64(totalBytes + written),
                                  totalBytes: expectedBytes, action: action)
        }

        totalBytes += n
    }

    if !FileManager.default.fileExists(atPath: outpath) || totalBytes == 0 || UInt64(totalBytes) != expectedBytes {
        globallogger.log("(fetchkcache) 内核缓存输出缺失")
        return false
    }

    guard let handle = FileHandle(forReadingAtPath: outpath) else {
        globallogger.log("(fetchkcache) 内核缓存输出缺失")
        return false
    }

    let magic = handle.readData(ofLength: 2)
    handle.closeFile()

    guard magic.count == 2, magic[magic.startIndex] == 0x30, magic[magic.index(after: magic.startIndex)] == 0x84 else {
        unlink(outpath)
        globallogger.log("(fetchkcache) 内核缓存输出无效")
        return false
    }

    if action.isCancellationRequested { return false }
    transferOwner.advance(downloadedBytes: expectedBytes, totalBytes: expectedBytes, action: action)
    guard transferOwner.complete(action: action) else { return false }
    transferCompleted = true
    globallogger.log("(fetchkcache) 内核缓存获取成功！")
    return true
}
