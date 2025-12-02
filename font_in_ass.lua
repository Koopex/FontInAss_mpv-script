--[[    https://github.com/Koopex/FontInAss_mpv-script

脚本功能: 请求 FontInAss 子集化处理本地 ass 字幕

------------------------------ 可用的快捷键 ------------------------------
#	script-binding font_in_ass/fonts  		#! 字体缺失列表
#	script-binding font_in_ass/openLog  	#! 打开字体缺失日志
]]

-------------------------------- 脚本配置 --------------------------------
local o ={

	----------------- api 必须配置, 其他可选 -----------------
	-- 设置你的FontInAss服务地址, 使用 8011 端口
	-- 示例 'http://192.168.1.100:8011/fontinass/process_bytes'
    api = 'http://192.168.1.100:8011/fontinass/process_bytes',


	---------------------- 提示缺失信息 ----------------------
	-- 是否提示缺失信息
	-- 2: "字体"或"字形"缺失时提示
	-- 1: 仅"字体"缺失时提示
	-- 0: 不提示
	-- 不管选哪个, 控制台都能查看全部信息
	reminder = 2,

	-- 提示方式
	-- false: (默认) 有 uosc 则使用 uosc 菜单, 没有则通过 osd 提示
	-- true: 总是使用 osd 提示 (即使有 uosc), 
	always_osd = false,

	-- osd 提示时, 复制字体名称的按键
	key_copy = 'Ctrl+c',

	-- osd 提示时, 查看日志的按键
	key_logs = 'f',

	-- osd 提示时, 关闭提示的按键
	key_close = 'SPACE',

	----------------------- 路径设置 -----------------------
    -- FontInAss 的日志路径,设置后可通过按键打开该文件所在位置
	-- 可以留空: [[]] 但不能注释掉
	-- 示例: [[/path/to/fontinass/logs/miss_logs.txt]]
    miss_logs_path = [[]],

	-- 子集化后字幕临时存放的文件夹, 播放结束自动删除字幕
	-- 如果需要更改, 必须提前创建好文件夹
	-- 示例: '~~home/_cache/fontinass_subs'  
	-- ~~home 代表mpv配置目录
    temp_dir = '~~home',
}
------------------------------ 脚本配置结束 ------------------------------



local mp = require 'mp'
local utils = require 'mp.utils'
local osd = mp.create_osd_overlay('ass-events') 
require 'mp.options'.read_options(o, mp.get_script_name())
if o.temp_dir:match('^~~home') then
	o.temp_dir = mp.command_native({"expand-path", o.temp_dir})
end


local items, message = {}, ''	--再次打开缺失信息菜单时使用
local miss = '' 				--供复制到剪切板使用
local subs = {}					--记录处理过的字幕, 防止重复处理
local uosc_version = nil		-- 检测uosc使用


local function checkUosc()
	--检查uosc
	if o.always_osd then return end
	mp.register_script_message('uosc-version', function(version)
		uosc_version = version
		mp.unregister_script_message('uosc-version')
	end)
end


local function decode(data)
	-- 用来解码缺失信息
	local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	data = string.gsub(data, "[^%a%d%+%/=]", "")
	local padding = string.sub(data, -2)
	local pad_bits = 0
	if padding == "==" then
		pad_bits = 4
		data = string.sub(data, 1, -3)
	elseif string.sub(padding, -1) == "=" then
		pad_bits = 2
		data = string.sub(data, 1, -2)
	end
	local result = ""
	local current_bits = 0
	local bit_count = 0
	for i = 1, #data do
		local char = string.sub(data, i, i)
		local byte = string.find(base64_chars, char) - 1
		if byte then
			current_bits = (current_bits * 64) + byte
			bit_count = bit_count + 6
			if bit_count >= 8 then
				bit_count = bit_count - 8
				local output_byte = math.floor(current_bits / (2^bit_count))
				result = result .. string.char(output_byte)
				current_bits = current_bits % (2^bit_count)
			end
		end
	end
	return result
end


local function openMenu()
	--不仅是第一次加载字幕, 通过快捷键也能调用
	if uosc_version and not o.always_osd then
		-- 打开uosc菜单
		-- 如果已经打开就关闭
		if mp.get_property_osd('user-data/uosc/menu/type', 'null') == 'font-loss' then
			mp.commandv('script-message-to', 'uosc', 'close-menu', 'font-loss')
		else
			mp.set_property('pause', 'yes')
			local menu_props = utils.format_json({
				type = 'font-loss',
				title = '字体缺失',
				items = items,
				callback = {mp.get_script_name(), 'menu_event'},
				footnote = '点击字体复制',
			})	
			mp.commandv('script-message-to', 'uosc', 'open-menu', menu_props)
		end
	else
		-- 根据 warn() 生成的文本发送消息
		-- 没有缺失信息
		if message == '' then 
			mp.osd_message('未缺失')
			return 
		end
		--有缺失信息, 暂停并发送消息提示
		mp.set_property_bool('pause', true)
		--解除快捷键绑定和osd消息,被多处调用
		local function remove()
			mp.remove_key_binding("temp_key_to_open_log")
			mp.remove_key_binding("temp_key_to_close")
			mp.remove_key_binding("temp_key_to_copy")
			osd:remove()
		end
		-- 处理暂停/继续事件, 其实不止设定的快捷键可以关闭消息, 其他方式暂停/继续也可以
		local function handle_pause(_, pause)
			if pause then return end
			mp.unobserve_property(handle_pause)
			remove()
		end
		mp.observe_property('pause', 'bool', handle_pause)
		-- 注册快捷键关闭消息
		mp.add_forced_key_binding(o.key_close, "temp_key_to_close", function()
			remove()
			mp.set_property_bool('pause', false)
		end)
		-- 注册复制缺失信息的快捷键
		mp.add_forced_key_binding(o.key_copy, "temp_key_to_copy", function()
			mp.commandv("run", "powershell", "set-clipboard", table.concat({'"', miss, '"'}))
			remove()
		end)
		-- 如果提供了fontInAss日志路径, 则多注册一个打开日志文件的快捷键
		if o.miss_logs_path ~= '' then
			mp.add_forced_key_binding(o.key_logs, "temp_key_to_open_log", function()
				remove()
				mp.commandv('script-binding', mp.get_script_name() .. '/openLog')
			end)
		end

		-- 先清空再刷新osd, 防止连续加载字幕导致重叠
		osd:remove()
		osd.data = message
		osd:update()
	end
end


local function warn(miss)
	-- 分离字体和字形信息
	local zt, zx = {}, {}
	for line in miss:gmatch("([^\r\n]+)") do
		if string.find(line:match("^(.-)%s*%["), "字体") then
			table.insert(zt, line:match("%[([^%]]+)%]"))
		else
			table.insert(zx, line:match("%[([^%]]+)%]")..'：'..line:match("%](.*)"))
		end
	end

	-- 输出到控制台
	for _, font in ipairs(zt) do
		mp.msg.error('字体缺失：'..font)
	end
	for _, font in ipairs(zx) do
		mp.msg.warn('缺少字形：'..font)
	end

	-- uosc 通知
	if uosc_version then 	
		for _, font in ipairs(zt) do
			table.insert(items, {
				title = font, 
				value = font,
				bold = true, 
			})
		end
		for _, font in ipairs(zx) do
			table.insert(items, {
				title = font, 
				value = font,
				hint = '缺少字形',
				bold = true, 
				muted = true,
			})
		end
		if o.miss_logs_path ~= '' then
			table.insert(items, {
				title = '📁 打开日志', 
				align = 'center',
			})
		end
	else
	-- osd 通知	
		-- 提前构建好osd消息, 后面可能会被快捷键调用, 不必反复构建
		if next(zt) then
			message = message .. '{\\fs32\\c&H6B6BFF&}⚠️ 字体缺失\\N'
			for _, s in ipairs(zt) do
				message = message .. '{\\fs26\\c&HFFFFFF&}• ' .. s .. '\\N'
			end
			message = message .. '\\N'
		end
		if next(zx) then
			message = message .. '{\\fs30\\c&H3DD9FF&}📝 缺少字形\\N'
			for _, s in ipairs(zx) do
				message = message .. '{\\fs26\\c&HFFFFFF&}• ' .. s .. '\\N'
			end
			message = message .. '\\N'
		end
		--头部的样式对后面的所有文本都生效, 除非被后面的样式覆盖
		local head = '{\\b1\\bord1.2\\blur1.5\\3c&000000&}'
		local tail = '{\\fs20\\bord1\\c&HEEEEEE&\\i1}*  '
		--如果提供了fontInAss,增加底部的快捷键提示
		if o.miss_logs_path ~= '' then
			tail = tail..string.format(
				'按 %s 关闭, 按 %s 复制, 按 %s 打开日志', 
				o.key_close, o.key_copy, o.key_logs
			)
		else
			tail = tail..string.format(
				'按 %s 关闭, 按 %s 复制', 
				o.key_close, o.key_copy
			)
		end 
		message = head..message..tail
	end

	-- 安静模式 或 (仅字体缺失时通知, 且没有字体缺失) 不通知
	if o.reminder == 0 or (o.reminder == 1 and not next(zt)) then return end

	-- 发送通知
	openMenu(true)
end


local function post(sid, path)
	-- curl
	local curl_command = {
		args = {
			'curl', '-s', '-i',
			'-X', 'POST', '--data-binary', '@' .. path,
			'-H', 'Content-Type: text/plain',
			o.api
		},
		cancellable = false
	}
	local result = utils.subprocess(curl_command)

	if result.status == 0 then
		-- 成功响应
		result = result.stdout
		local text = utils.format_json(result)

		-- text 包含了缺失信息和字幕文本
		miss = text:match("error: ([^\\]*)")

		-- 缺失信息需要Base64解码
		miss = decode(miss)

		-- 保存字幕到临时文件
		local startPos = text:find("%[Script Info%]")
		local subtitle = startPos and text:sub(startPos) or nil
		subtitle = '["' .. subtitle .. ']'
		subtitle = utils.parse_json(subtitle)[1]
		local _, filename = utils.split_path(path)
		local temp_file = utils.join_path(o.temp_dir, filename)
		local out_file = io.open(temp_file, "w"):write(subtitle):close()

		-- 暂时取消 on_sub_changed() 的监听
		mp.commandv("sub-remove", sid)
		-- 临时监听, 字幕成功加载以后再恢复 on_sub_changed() 监听
		local function temp_ob(_, sub)
			if sub and sub.id then
				--新字幕加载成功, 解除临时监听, 恢复主要监听
				mp.unobserve_property(temp_ob)
				mp.observe_property('current-tracks/sub', 'native', on_sub_changed)
			end
		end
		mp.observe_property('current-tracks/sub', 'native', temp_ob)
		mp.commandv("sub-add", temp_file, "select")
		-- 记录处理过的字幕路径, 以便再次加载时不再处理
		table.insert(subs, temp_file)

		-- 处理完成
		mp.msg.info('子集化完成')

		-- 不管哪种提示方式都要warn(), 还需要输出到控制台
		if miss~= '' then warn(miss) end
	end
end


local function on_sub_changed(_, sub)
	-- {		表格 sub 的结构
	--   "codec": "ass",
	--   "codec-desc": "Advanced Sub Station Alpha",
	--   "id": 1,
	--   "forced": false,
	--   "default": false,
	--   "type": "sub",
	--   "title": "default.zh-cn.诸神.ass",
	--   "image": false,
	--   "albumart": false,
	--   "dependent": false,
	--   "visual-impaired": false,
	--   "hearing-impaired": false,
	--   "external": true,
	--   "selected": true,
	--   "main-selection": 0,
	--   "external-filename": "\\\\NAS\\media2\\动画\\日本动画\\我心里危险的东西 (2023)\\Season 01\\我心里危险的东西 S01E01 [1080p BD] -AI-Raws@ANK.default.zh-cn.诸神.ass",
	--   "ff-index": 0
	-- }

	-- 更换字幕,清空旧字幕的缺失信息
	items, message, miss = {}, '', ''

	if not sub then return end
		
	local sid, path 
	-- 由于 external-filename 有减号, 不能使用 sub.external-filename
	if sub.external and sub.codec == "ass" and not sub["external-filename"]:match('^http') then
		-- 路径统一为正斜杠,方便下面的查重
		sid, path = sub.id, sub["external-filename"]:gsub("\\", "/")
	end

	if not path then return end

	-- 当前视频没处理过字幕, 直接处理
	if not next(subs) then	
		post(sid, path)
	else
		-- 已经处理过一些字幕, 检查当前字幕是不是处理过的
		local found = false	
		for _, item in ipairs(subs) do
			if item == path then
				-- 已经子集化了, 忽略
				found = true;
				break
			end
		end
		-- 没处理过, 处理
		if not found then
			post(sid, path)
		end
	end
end


local function delete()
	-- 视频结束删除临时生成的字幕
	if next(subs) then
		for _, s in ipairs(subs) do
			os.remove(s)
		end
	end
	subs = {}
end


local function menu_event(json)
	--发送uosc菜单的响应
	local event = utils.parse_json(json)
	if event.type == 'activate' then
		--点击条目复制
		if event.value then
			mp.osd_message('已复制', 2)
			mp.commandv("run", "powershell", "set-clipboard", table.concat({'"', event.value, '"'}))
		else
			--打开日志的按钮没设置value, 用来区分
			mp.commandv('script-binding', mp.get_script_name() .. '/openLog')
		end
	elseif event.type == 'close' then
		--关闭菜单自动继续
		mp.set_property('pause', 'no')
	end
end


local function openLog()
	--打开FontInAss日志
	if o.miss_logs_path ~= '' then
		utils.subprocess_detached(
			{args = {'explorer', '/select,', o.miss_logs_path}, 
			cancellable = false})
	else
		mp.osd_message('未设置字体缺失日志文件路径', 5)
	end
end

checkUosc()
mp.register_event('end-file', delete)
mp.observe_property('current-tracks/sub', 'native', on_sub_changed)
mp.register_script_message('menu_event', menu_event)
mp.add_key_binding(nil, 'openLog', openLog)
mp.add_key_binding(nil, 'fonts', openMenu)
