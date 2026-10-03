import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Profile, SubscriptionInfo } from './FlClashStore';

export interface ProfileBackupData {
  version: number;
  profiles: Profile[];
  selectedProfile: number;
  preferredMode: string;
  selections: Record<string, Record<string, string>>;
}

const MAX_BACKUP_BYTES: number = 32 * 1024 * 1024;

function objectValue(value: Object, label: string): Record<string, Object> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label}格式错误`);
  }
  return value as Record<string, Object>;
}

function textValue(value: Object, label: string, allowEmpty: boolean = false): string {
  if (typeof value !== 'string' || (!allowEmpty && (value as string).trim().length === 0)) {
    throw new Error(`${label}必须是${allowEmpty ? '' : '非空'}文本`);
  }
  return value as string;
}

function numberValue(value: Object, label: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value as number) || (value as number) < 0) {
    throw new Error(`${label}必须是有效的非负数`);
  }
  return value as number;
}

function integerValue(value: Object, label: string): number {
  const number = numberValue(value, label);
  if (!Number.isSafeInteger(number)) { throw new Error(`${label}必须是有效整数`); }
  return number;
}

/** Validate every field before returning a detached, whitelisted backup. */
export function parseProfileBackup(content: string): ProfileBackupData {
  if (content.length === 0 || content.length > MAX_BACKUP_BYTES ||
    new util.TextEncoder().encodeInto(content).byteLength > MAX_BACKUP_BYTES) {
    throw new Error('备份文件为空或超过 32 MB');
  }
  let parsed: Object;
  try { parsed = JSON.parse(content); } catch (_) { throw new Error('备份不是有效的 JSON 文件'); }
  const root = objectValue(parsed, '备份');
  if (root['version'] !== 1) { throw new Error('不支持此备份版本'); }
  if (!Array.isArray(root['profiles'])) { throw new Error('备份缺少配置列表'); }
  const rawProfiles = root['profiles'] as Object[];
  if (rawProfiles.length > 1000) { throw new Error('备份配置数量超过 1000'); }
  const profiles: Profile[] = [];
  const ids: number[] = [];
  rawProfiles.forEach((raw: Object, index: number) => {
    const label = `第 ${index + 1} 个配置`;
    const item = objectValue(raw, label);
    const id = integerValue(item['id'], `${label} ID`);
    if (id === 0 || ids.includes(id)) { throw new Error(`${label} ID 无效或重复`); }
    ids.push(id);
    const profile: Profile = {
      id,
      name: textValue(item['name'], `${label}名称`),
      source: textValue(item['source'], `${label}来源`, true),
      content: textValue(item['content'], `${label}内容`),
      updatedAt: integerValue(item['updatedAt'], `${label}更新时间`)
    };
    if (item['subscription'] !== undefined) {
      const rawSubscription = objectValue(item['subscription'], `${label}订阅信息`);
      const subscription: SubscriptionInfo = {
        upload: numberValue(rawSubscription['upload'], `${label}上传量`),
        download: numberValue(rawSubscription['download'], `${label}下载量`),
        total: numberValue(rawSubscription['total'], `${label}总量`),
        expire: numberValue(rawSubscription['expire'], `${label}到期时间`)
      };
      profile.subscription = subscription;
    }
    profiles.push(profile);
  });
  const selectedProfile = integerValue(root['selectedProfile'], '选中配置');
  if ((profiles.length === 0 && selectedProfile !== 0) ||
    (profiles.length > 0 && !ids.includes(selectedProfile))) {
    throw new Error('备份中的选中配置不存在');
  }
  const preferredMode = textValue(root['preferredMode'], '出站模式');
  if (!['rule', 'global', 'direct'].includes(preferredMode)) { throw new Error('备份中的出站模式无效'); }
  const rawSelections = objectValue(root['selections'], '节点选择');
  const selections: Record<string, Record<string, string>> = {};
  Object.keys(rawSelections).forEach((profileKey: string) => {
    if (!ids.some((id: number) => String(id) === profileKey)) {
      throw new Error('节点选择引用了不存在的配置');
    }
    const rawChoices = objectValue(rawSelections[profileKey], '代理组选择');
    const choices: Record<string, string> = {};
    Object.keys(rawChoices).forEach((group: string) => {
      if (group.trim().length === 0 || ['__proto__', 'constructor', 'prototype'].includes(group)) {
        throw new Error('代理组名称无效');
      }
      choices[group] = textValue(rawChoices[group], '选中节点');
    });
    selections[profileKey] = choices;
  });
  return { version: 1, profiles, selectedProfile, preferredMode, selections };
}

/** The file contains subscription credentials; only write to the location chosen by the user. */
export async function exportProfileBackup(context: common.UIAbilityContext, data: ProfileBackupData): Promise<boolean> {
  // Round-trip validation also strips accidental controller/runtime fields supplied by callers.
  const clean = parseProfileBackup(JSON.stringify(data));
  const content = JSON.stringify(clean, null, 2);
  if (new util.TextEncoder().encodeInto(content).byteLength > MAX_BACKUP_BYTES) { throw new Error('备份文件超过 32 MB'); }
  const selector = new picker.DocumentViewPicker(context);
  const date = new Date().toISOString().slice(0, 10);
  const uris = await selector.save({ newFileNames: [`OHClash-backup-${date}.json`], fileSuffixChoices: ['JSON|.json'] });
  if (uris.length === 0) { return false; }
  const file = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try { fs.writeSync(file.fd, content); } finally { fs.closeSync(file); }
  return true;
}

/** Returns undefined when dismissed. Does not mutate configuration or start/stop a VPN. */
export async function importProfileBackup(context: common.UIAbilityContext): Promise<ProfileBackupData | undefined> {
  const selector = new picker.DocumentViewPicker(context);
  const uris = await selector.select({ maxSelectNumber: 1, fileSuffixFilters: ['JSON|.json'] });
  if (uris.length === 0) { return undefined; }
  const source = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
  const cachePath = `${context.cacheDir}/ohclash-restore-${util.generateRandomUUID()}.json`;
  try {
    if (fs.statSync(source.fd).size > MAX_BACKUP_BYTES) { throw new Error('备份文件超过 32 MB'); }
    fs.copyFileSync(source.fd, cachePath);
    return parseProfileBackup(fs.readTextSync(cachePath));
  } finally {
    fs.closeSync(source);
    try { fs.unlinkSync(cachePath); } catch (_) {}
  }
}
