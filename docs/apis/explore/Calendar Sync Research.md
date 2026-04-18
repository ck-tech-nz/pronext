# Calendar Sync Research

>  Important Resources：
>  [GitHub - google-api-python-client](https://github.com/googleapis/google-api-python-client)
>  [Google APIs Explorer Google 接口列表，可以看说明，Sample Code，在线试用](https://developers.google.com/apis-explorer)
>  [API Reference  |  Google Calendar  |  Google for Developers](https://developers.google.com/calendar/api/v3/reference)

## 逻辑思路

对于冰箱贴pad，我们不需要用Google/Microsoft OAuth 实现 django 用户创建+登录
我们需要的仅仅是有：
1. 一个项目管理所有资源
2. OAuth 开放授权ID
3. OAuth 密钥 credential
4. 前端 JS 用 credentials.json 跳转调用 OAuth，完成登录返回 token 给后端
   ```json
	{
		"username": "asdfa@pronext-pad.com",
		"app": "google-calendar",
		"token": "xcasdas-dasdf-asd-as-dfasdfasdfasd-fas-dfasdfasf"
	}
	```
5. 后端存储这个用户的对应token
6. Watch 变更
7. Django 根据变更通知修改本地的日程

BTW: 并未看到有关类似邮件协议同步日历的接口
[API Reference  |  Google Calendar  |  Google for Developers](https://developers.google.com/calendar/api/v3/reference)

## Google Calendar
[Google Cloud Platform](https://console.cloud.google.com/apis/credentials/consent?project=pronext-pad)

### Setup APIs and Services

#### 1. OAuth consent screen  
	开放授权- “同意屏幕” 小弹窗请求用户同意开放授权给pronext
	选外部使用，将来正式上线还需要完善同意屏上的全部信息 OAuth 是获得其他 Google 用户数据的必备条件，所以先做
1. Enable Google Calendar API
2. Scope - add Google Calendar API
   ![[Pasted image 20240512093848.png]]
3.  Test users
   Add two test users

#### 1. 创建Credentials
	[Google Cloud Platform](https://console.cloud.google.com/apis/credentials?project=pronext-pad)

1. OAuth client ID - （choose `web application`)
   A client ID is used to identify a single app to Google's OAuth servers. If your app runs on multiple platforms, each will need its own client ID. See [Setting up OAuth 2.0](https://developers.google.com/identity/protocols/oauth2/?hl=en_GB)  for more information. [Learn more](https://support.google.com/cloud/answer/6158849?hl=en_GB)  about OAuth client types.


### Sync Calendar
