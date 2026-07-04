# fontInAss_mpv-script

在 mpv 播放器中请求 [fontInAss](https://github.com/RiderLty/fontInAss)/[FontInAss](https://github.com/Yuri-NagaSaki/FontInAss) 子集化处理本地ass字幕。

# 主要功能

- [fontInAss](https://github.com/RiderLty/fontInAss): 实时将字体子集化后嵌入ass的小工具，用于在未安装对应字体的系统上正确显示字幕。
- [FontInAss](https://github.com/Yuri-NagaSaki/FontInAss): FontInAss 是一个开源的字幕字体子集化工具。将 ASS/SSA/SRT 字幕文件上传后，系统自动从在线字体库中匹配字幕引用的字体，提取实际使用的字符生成极小的子集化字体，并嵌入到字幕文件中。

- 本脚本: 把外挂的 ass 字幕发送给服务端处理，并在 mpv 中提示缺少的字体和字形。播放**本地视频**或使用[embyToLocalPlayer](https://github.com/kjtsune/embyToLocalPlayer) 的"读取硬盘模式"也能实时使用字体子集化的字幕。

![image](https://github.com/Koopex/fontInAss_mpv-script/blob/main/%E9%A2%84%E8%A7%88/%E4%B8%A4%E7%A7%8D%E6%8F%90%E7%A4%BA%E6%96%B9%E5%BC%8F.png)
# 使用方法

1. 保存`font_in_ass.lua`到mpv配置目录的`scripts`文件夹  
2. 编辑`font_in_ass.lua`：填写 fontInAss 的服务地址等  

# 感谢!
- [fontInAss](https://github.com/RiderLty/fontInAss)
- [FontInAss](https://github.com/Yuri-NagaSaki/FontInAss)
- [uosc](https://github.com/tomasklaen/uosc)
- [embyToLocalPlayer](https://github.com/kjtsune/embyToLocalPlayer)
- [mpv](https://github.com/mpv-player/mpv)
