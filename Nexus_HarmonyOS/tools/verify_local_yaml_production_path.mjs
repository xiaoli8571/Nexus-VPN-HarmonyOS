import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const samplePath = process.argv[2];
if (!samplePath) throw new Error('usage: node tools/verify_local_yaml_production_path.mjs <yaml-path>');

const bytes = fs.readFileSync(path.resolve(samplePath));
const text = bytes.toString('utf8');

function sectionLines(yaml, sectionName) {
  const out = [];
  let inSection = false;
  for (let line of yaml.split('\n')) {
    if (line.startsWith('\uFEFF')) line = line.slice(1);
    if (!line.startsWith(' ') && !line.startsWith('\t')) {
      const trimmed = line.trim();
      if (trimmed.startsWith(`${sectionName}:`)) {
        inSection = true;
        continue;
      }
      if (inSection && trimmed && !trimmed.startsWith('#')) break;
    }
    if (inSection) out.push(line);
  }
  return out;
}

function proxyItemGroups(yaml) {
  const section = sectionLines(yaml, 'proxies');
  const content = section.filter(line => {
    const trimmed = line.trimStart();
    return trimmed.length > 0 && !trimmed.startsWith('#');
  });
  if (content.length === 0) return [];
  const minIndent = Math.min(...content.map(line => line.length - line.trimStart().length));
  const normalized = section.filter(line => line.trim().length > 0).map(line => `  ${line.slice(minIndent)}`);
  const items = [];
  let current = null;
  for (const line of normalized) {
    if (line.startsWith('  - ')) {
      if (current !== null) items.push(current);
      current = [line];
    } else if (current !== null) {
      current.push(line);
    }
  }
  if (current !== null) items.push(current);
  return items;
}

function parseCore(item) {
  const joined = item.join('\n');
  const name = joined.match(/(?:^|[,{\n])\s*name:\s*([^,\n}]+)/)?.[1]?.trim() ?? '';
  const type = joined.match(/(?:^|[,{\n])\s*type:\s*([^,\n}]+)/)?.[1]?.trim() ?? '';
  const server = joined.match(/(?:^|[,{\n])\s*server:\s*([^,\n}]+)/)?.[1]?.trim() ?? '';
  const portText = joined.match(/(?:^|[,{\n])\s*port:\s*(\d+)/)?.[1] ?? '';
  const port = Number(portText);
  return { name, type, server, port };
}

function importableCount(yaml) {
  return proxyItemGroups(yaml)
    .map(parseCore)
    .filter(node => node.name.length > 0 && node.type.length > 0 && node.server.length > 0 && Number.isInteger(node.port) && node.port > 0 && node.port <= 65535)
    .length;
}

function readOnceLikeDocumentProvider(buffer, providerChunkSize) {
  return buffer.subarray(0, Math.min(providerChunkSize, buffer.length));
}

function readFullyLikeDocumentProvider(buffer, providerChunkSize) {
  const chunks = [];
  let offset = 0;
  while (offset < buffer.length) {
    const end = Math.min(offset + providerChunkSize, buffer.length);
    const chunk = buffer.subarray(offset, end);
    if (chunk.length <= 0) break;
    chunks.push(chunk);
    offset += chunk.length;
  }
  return Buffer.concat(chunks);
}

const fullGroups = proxyItemGroups(text);
const fullImportable = importableCount(text);
assert.equal(fullGroups.length, 22, '原始 YAML 应切分出 22 个 proxies 条目');
assert.equal(fullImportable, 21, '原始 YAML 应有 21 个可导入节点');

let twoNodeChunk = -1;
for (let size = 1; size < bytes.length; size += 1) {
  if (importableCount(readOnceLikeDocumentProvider(bytes, size).toString('utf8')) === 2) {
    twoNodeChunk = size;
    break;
  }
}
assert.notEqual(twoNodeChunk, -1, '应能构造一次短读仅暴露 2 个节点的文档提供器行为');

const oneShotCount = importableCount(readOnceLikeDocumentProvider(bytes, twoNodeChunk).toString('utf8'));
const fullyReadBytes = readFullyLikeDocumentProvider(bytes, twoNodeChunk);
const fullReadCount = importableCount(fullyReadBytes.toString('utf8'));
assert.equal(oneShotCount, 2, '单次 readSync 短读应复现真机只导入 2 个节点');
assert.equal(fullyReadBytes.length, bytes.length, '循环读取必须取回完整文件');
assert.equal(fullReadCount, 21, '循环读取后的生产语义应保留 21 个可导入节点');

console.log(`PASS local YAML production-path regression: bytes=${bytes.length}, groups=${fullGroups.length}, importable=${fullImportable}`);
console.log(`REPRO short-read chunk=${twoNodeChunk}, one-shot=${oneShotCount}, read-fully=${fullReadCount}`);
