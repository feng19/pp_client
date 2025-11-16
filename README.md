# PpClient

**Port to Port VPN Client**

## Data Flow

request -> endpoint -> match condition to profile -> transfer data to one of profile.servers

## TODO

### Web管理界面 (LiveView)

#### 1. Endpoint管理页面 (`/admin/endpoints`)
- [ ] 列表视图
  - [ ] 显示所有endpoints（端口、类型、状态、IP地址）
  - [ ] 实时状态指示器（运行中/已停止）
  - [ ] 按状态筛选（全部/已启用/已禁用）
  - [ ] 搜索功能（按端口或类型）
- [ ] CRUD操作
  - [ ] 创建新endpoint（表单验证：端口范围1-65535、IP格式、类型选择）
  - [ ] 编辑现有endpoint（支持热更新）
  - [ ] 删除endpoint（带确认对话框）
- [ ] 状态控制
  - [ ] 启用/禁用切换开关
  - [ ] 批量操作（批量启用/禁用/删除）
  - [ ] 重启endpoint功能

#### 2. Profile管理页面 (`/admin/profiles`)
- [ ] 列表视图
  - [ ] 显示所有profiles（名称、类型、状态、服务器数量）
  - [ ] 搜索功能
- [ ] CRUD操作
  - [ ] 创建profile（名称唯一性验证）
  - [ ] 编辑profile（支持添加/删除服务器）
  - [ ] 删除profile（检查是否被condition引用）
  - [ ] 复制profile功能
- [ ] 服务器配置
  - [ ] 添加/编辑服务器列表
  - [ ] 服务器连接测试
  - [ ] 服务器优先级排序
- [ ] 状态管理
  - [ ] 启用/禁用切换
  - [ ] 批量操作

#### 3. Condition管理页面 (`/admin/conditions`)
- [ ] 列表视图
  - [ ] 显示所有conditions（ID、规则、关联profile、状态）
  - [ ] 按状态筛选
  - [ ] 按profile筛选
  - [ ] 拖拽排序（优先级调整）
- [ ] CRUD操作
  - [ ] 从失败的 connect_failed 列表中快速创建 condition
  - [ ] 创建condition（正则表达式验证）
  - [ ] 编辑condition
  - [ ] 删除condition（带确认）
  - [ ] 批量导入/导出（JSON格式）
- [ ] 规则配置
  - [ ] 常用规则模板
- [ ] 关联管理
  - [ ] Profile选择器（下拉列表）
  - [ ] 显示关联的profile详情
  - [ ] 快速切换profile

### 技术实现要点

#### LiveView组件设计
- [ ] 创建共享组件
  - [ ] `<.table>` - 通用数据表格组件（支持排序、分页）
  - [ ] `<.form_modal>` - 模态表单组件
  - [ ] `<.status_badge>` - 状态徽章组件
  - [ ] `<.confirm_dialog>` - 确认对话框组件
  - [ ] `<.search_bar>` - 搜索栏组件

#### 实时更新
- [ ] 使用Phoenix.PubSub广播状态变更
- [ ] LiveView自动订阅相关主题
- [ ] 实现乐观UI更新

#### 表单验证
- [ ] 使用Ecto.Changeset进行数据验证
- [ ] 客户端实时验证（phx-change）
- [ ] 友好的错误提示

#### 用户体验
- [ ] 响应式设计（支持移动端）
- [ ] 加载状态指示器
- [ ] Toast通知（成功/错误/警告）
- [ ] 键盘快捷键支持
- [ ] 暗色主题支持

### 测试计划
- [ ] LiveView集成测试
  - [ ] 测试CRUD操作
  - [ ] 测试表单验证
  - [ ] 测试实时更新
- [ ] 组件单元测试
- [ ] E2E测试（使用Wallaby）

### 文档
- [ ] API文档（ExDoc）
- [ ] 用户使用指南
- [ ] 部署文档
- [ ] 配置示例文件
