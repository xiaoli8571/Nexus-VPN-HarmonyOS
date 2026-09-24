/**
 * PrivateFs 的 fileIo 生产实现（目录/文件最小权限 + 有界读取 + 独立删除）。
 * 与 RuntimeFilePolicy 分离，使纯策略可在 ohosTest 中脱离沙箱验证。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
// @kit.CoreFileKit 的 fileIo **没有** chmod/chmodSync（只有 open/read/write/stat/unlink/mkdir/listFile），
// 收窄权限位的唯一官方入口是兼容模块 @ohos.fileio（deprecated since API 9，但仍可用）。
// 仅为 chmod 引入该模块，其余文件操作一律走 @kit.CoreFileKit。
import fileIo from '@ohos.fileio';
import { util } from '@kit.ArkTS';
import {
  MAX_STATE_FILE_BYTES, PrivateFs, SyncReadResult
} from './RuntimeFilePolicy';

const TAG = 'PrivateFileStore';

/**
 * 收窄权限位（目录 0700 / 文件 0600）。
 * 失败不致命：应用私有目录本就只有本应用 uid 可访问，chmod 属纵深防御。
 */
export function chmodPrivate(path: string, mode: number): void {
  fileIo.chmodSync(path, mode);
}

/**
 * 确保目录存在且为最小权限（0700）。
 * 已存在时 mkdir 会抛错 —— 属正常，继续 chmod 收窄。
 */
export function ensurePrivateDir(dir: string): void {
  try {
    fs.mkdirSync(dir, true);
  } catch (e) {
    // 目录已存在属正常
  }
}

/** 共享的 fileIo 实现实例（无状态，可全局复用） */
export class FileIoPrivateFs implements PrivateFs {
  writePrivate(path: string, content: string): void {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
    } finally {
      // fd 必须关闭：writeSync 抛错（磁盘满/权限）时同样释放
      fs.closeSync(file);
    }
  }

  /**
   * 读取上限内的文本。用 statSync(path) 而非 statSync(fd)，并在 finally 中
   * closeSync —— 修复此前 statSync/readSync/decode 抛错时 fd 泄漏。
   */
  readCapped(path: string, maxBytes: number): SyncReadResult {
    const limit = maxBytes > 0 ? maxBytes : MAX_STATE_FILE_BYTES;
    let file: fs.File | null = null;
    try {
      const stat = fs.statSync(path);
      if (stat.size <= 0) {
        return { ok: true, text: '', truncated: false };
      }
      const readLen = stat.size > limit ? limit : stat.size;
      const truncated = stat.size > limit;
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(readLen);
      const got = fs.readSync(file.fd, buf);
      const text = util.TextDecoder.create('utf-8')
        .decodeToString(new Uint8Array(buf, 0, got > 0 ? got : 0));
      return { ok: true, text: text, truncated: truncated };
    } catch (e) {
      return { ok: false, text: '', truncated: false };
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 关闭失败不覆盖已有结果
        }
      }
    }
  }

  remove(path: string): boolean {
    try {
      fs.unlinkSync(path);
      return true;
    } catch (e) {
      // 文件不存在或删除失败：返回 false，由调用方继续处理其他文件
      return false;
    }
  }

  exists(path: string): boolean {
    try {
      fs.statSync(path);
      return true;
    } catch (e) {
      return false;
    }
  }
}

/** 单例：避免每处 new */
export const privateFs: FileIoPrivateFs = new FileIoPrivateFs();

/** 日志标签出口（避免调用方重复引入常量） */
export const PRIVATE_FS_TAG = TAG;
