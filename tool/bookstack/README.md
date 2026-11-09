
部署bookstack

1. 目录说明：

./data/uploads：用来存放图片，wiki中创建的图片
./data/logs：用来存储日志
./data/storage：用来存放上传的文件

2. 拷贝.env.template到.env

3. 配置数据库

4. 配置.env的APP_KEY（可以使用`scripts/generate_key.sh 32`生成）并上前缀`base64:`, 比如
APP_KEY=base64:Mmyc25PCqMM35TUqz9YFOnGdt7n7LlKUeAwV9qwZdoU=

5. 启动bookstack容器服务，执行命令：docker compose up -d

初始化工作

1. 部署成功后，需要使用默认管理员登陆（admin@admin.com/password）
2. 修改管理员密码和邮箱信息
3. 通过管理配置是否能够注册、角色权限、应用描述等信息。
