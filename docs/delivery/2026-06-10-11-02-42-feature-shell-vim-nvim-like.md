# Vim 类 Neovim 插件配置交付说明

## 变更摘要

- 扩展 `config/editors/vim/vimrc`，加入类 Neovim 的常用快捷键分组。
- 使用 Vim 8 package 目录安装插件，不引入额外插件管理器。
- 新增 fzf / fzf.vim 作为 Telescope 类文件、buffer、历史、命令、文本搜索入口。
- 新增 vim-which-key、vim-gitgutter、vim-fugitive、vim-surround、vim-commentary、auto-pairs、vim-easymotion、lightline.vim。
- 补全只使用 Vim 原生命令、文件路径、buffer、tag 等基础补全，不启用 LSP / coc 补全。
- `install.sh uninstall --components vim` 支持显式卸载 Vim 配置和本脚本托管的 Vim 插件。

## 常用入口

```bash
bash install.sh install --components vim
bash install.sh uninstall --components vim
```

## 主要快捷键

- `,ff`：查找文件
- `,fF`：查找文件并预览
- `,ft`：全文搜索
- `,fb`：切换 buffer
- `,fc`：命令列表
- `,fr`：最近文件
- `,fw`：保存所有文件
- `,e`：切换 NERDTree
- `,tk`：显示 which-key
- `<C-Space>`：插入模式触发文件路径补全
- `<Tab>` / `<S-Tab>`：插入模式补全项上下选择

## 保护措施

- 安装时如果目标插件目录已存在但不是期望的 Git remote，会保留用户目录并跳过 clone。
- 卸载时只删除 state 标记为本脚本托管且 Git remote 匹配的插件目录。
- 缺少 state 文件时，卸载只清理空目录，不删除用户已有 Vim 插件。
- `.vimrc` 仍沿用原有备份逻辑，避免覆盖用户配置后不可恢复。

## 验证

- `bash bootstrap/verify.sh syntax`
- `bash bootstrap/verify.sh integration`
- `vim -Nu config/editors/vim/vimrc -n -es -i NONE -c 'if v:errmsg != "" | echo v:errmsg | cquit | endif' -c 'qa!'`
- `nvim -Nu config/editors/vim/vimrc --headless -i NONE +"if v:errmsg != '' | echo v:errmsg | cquit | endif" +qa`
