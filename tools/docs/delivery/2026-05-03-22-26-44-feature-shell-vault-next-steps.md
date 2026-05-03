# Vault next step hints

## 变更摘要

- 修改脚本：`vault/vault-manager`
- 新增安装完成后的下一步提示
- 新增初始化完成后的下一步提示

## 行为说明

安装成功后输出：

```text
vault-manager init --key-shares 1 --key-threshold 1 --out /opt/vault/init/vault-init.json
vault-manager unseal --keys-file /opt/vault/init/vault-init.json
vault-manager status --token-file /opt/vault/init/vault-init.json
```

初始化成功后输出：

```text
vault-manager unseal --keys-file <init-json>
source ~/vault.acl
vault-manager status --token-file <init-json>
```

## 影响范围

- 仅增加成功路径提示
- 不改变 install、init、unseal、status 的执行逻辑
- 不新增副作用，不读取或打印 token 内容

## 验证情况

- 已执行：`bash -n vault/vault-manager`
- 已执行：`shellcheck vault/vault-manager`
