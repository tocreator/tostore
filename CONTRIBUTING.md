# 贡献指南

感谢你考虑为 ToStore 做出贡献！

## 开发流程

1. Fork 项目
2. 创建你的特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交你的修改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启一个 Pull Request

## 代码规范

- 遵循 [Effective Dart](https://dart.dev/guides/language/effective-dart) 编码规范
- 使用 `dart format` 格式化代码
- 确保通过所有测试 (`dart test`)
- 保持代码覆盖率

## 提交 Pull Request

1. PR 标题清晰描述改动
2. 详细描述改动的动机和具体实现
3. 确保所有 CI 检查通过
4. 更新相关文档

## 报告 Bug

1. 使用 GitHub Issues
2. 描述问题和复现步骤
3. 提供环境信息和错误日志

## 功能建议

1. 先在 Discussions 中讨论
2. 说明使用场景和解决方案
3. 等待社区反馈

## 开发环境设置

```bash
# 获取依赖
dart pub get

# 运行测试
dart test

# 检查代码格式
dart format .

# 运行分析器
dart analyze
```

## 文档贡献

- 改进 README
- 补充 Wiki 文档
- 添加代码示例
- 修正错别字

## 版本发布

- 遵循 [语义化版本](https://semver.org/lang/zh-CN/)
- 更新 CHANGELOG.md
- 标记版本号


## 许可证

贡献代码时，你同意将其授权为 [MIT 许可证](LICENSE)。 