# LibrePhotos

云吞插件：把共享文件夹 photos 里的照片整理成相册，按人脸、地点和画面内容搜索。装好打开网页就是自己的账号——登录走云吞的 OIDC。

## 登录怎么接的

LibrePhotos 只有一个免费开源版（MIT，没有付费版），1.1.0 起在应用里自带 OpenID Connect 登录（django-allauth，见 [1.1.0 发版说明](https://github.com/LibrePhotos/librephotos/releases/tag/1.1.0)）。插件因此用 `sso: oidc`：

- 网页地址直达应用的 OIDC 起点（`webui.path`），打开就跳云吞身份方，不再看到应用的登录页；
- 首次安装时按云吞用户名和邮箱建好应用管理员（不设密码，密码登录没有可用口令），SSO 身份按已验证邮箱链到这个账号；
- OIDC 客户端（allauth SocialApp）由插件的一次性服务在每次重建容器时按核心注入的变量核对重建，核心重装后密钥换了也能登录。

## 照片放哪

- 照片库就是共享文件夹 `photos`（读写）：应用按上游默认允许网页上传（写进库里的 `uploads/`）、删除和把元数据写回文件。
- 缩略图、识别模型、数据库、日志都在插件自己的数据目录，升级和重装（保数据）不丢。

## 邮件

应用发的信（找回密码）走云吞的内部邮箱，会出现在收件人的 Wonton 私聊里；只发给家里人，外部邮箱发不出。

## 识别模型

人脸识别、语义搜索等模型在首次扫描时自动下载（Hugging Face 等公网地址），之后全部本地运行。主机连不上公网时，在云吞的出网代理设置里配好代理即可。

## 图标

`icon.png` 用 LibrePhotos 官方标志（白色底上原样缩放），来源和许可见 [NOTICE](NOTICE)。

---

开发流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)，更新套件用 `scripts/dev.sh kit-update`。
