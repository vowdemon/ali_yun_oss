# 项目上下文信息

- 版本1.2.0已成功发布，包含两个主要功能：1)自定义域名(CNAME)支持解决GitHub Issue #3，2)V4签名URL自定义查询参数支持解决GitHub Issue #5。已更新双语Changelog、pubspec.yaml版本号，并推送到GitHub仓库，创建了v1.2.0标签。
- 为example.dart添加大文件上传功能(1.3)和修改下载示例，使用PDF文件：2025.04.15云樾府A区高压喷雾设备购销安装合同17628元.pdf
- 重构大文件示例：将硬编码的PDF文件路径移至config.dart配置文件，并将敏感资产目录添加到.gitignore中防止业务文件泄露
- 为example.dart添加了示例1.4(使用签名URI和Headers上传PDF)和示例2.1(使用签名URI和Headers下载文件)，展示了buildOssUri()和createSignedHeaders()底层方法的直接使用
