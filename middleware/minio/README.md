如何启动minio服务？

以下是需要域名方式来进行访问，即使用nginx代理Web和API的方法，需要处理的步骤
1. 配置DNS域名解析
2. 在域名解析对应的公网ip机器上配置nginx， 使用location /web/ 和 location / 来区分，前面的location代理web端访问，后面的location代理API访问。 配置文件请参考minio.conf ， 修改servername对应的值之后放到/etc/nginx/conf.d/目录下
3. 在域名解析对应的公网ip机器上生成TLS证书，通常使用certbot命令

以下是在minio的启动节点上进行的操作
1. 拷贝.env.template到.env，然后根据需要修改里面的参数，使用域名访问时需要容器配置环境变量MINIO_BROWSER_REDIRECT_URL=<url>/web。如果你想使用新密码，请使用scripts/generate_password.sh <password length>生成
2. 执行命令：docker compose up -d



如何测试？
1. python3 -m venv venv
2. source venv/bin/activate
3. pip3 install minio
4. pip3 install dotenv
5. 配置.env文件
6. python3 test.py

