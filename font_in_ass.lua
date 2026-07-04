--[[	https://github.com/Koopex/FontInAss_mpv-script

脚本功能: 请求 FontInAss 子集化处理本地 ass 字幕

------------------------------ 可用的快捷键 ------------------------------
#	script-binding font_in_ass/fonts  		#! 字体缺失（OSD）
#	script-binding font_in_ass/openLog  	#! 字体缺失（网页）
]]

-------------------------------- 脚本配置 --------------------------------
local o ={

	--================[[ 服务地址必须配置 ]]================--
	-- 设置你的FontInAss服务地址, 需要填写完整的路径
	-- 可以填写多个服务器,优先请求第一个,失败后一次尝试后面的
	-- 支持 https://github.com/RiderLty/fontInAss
	-- 和 https://github.com/Yuri-NagaSaki/FontInAss
	-- 示例 'http://192.168.1.100:8011/api/subset,https://second.server/api/subset'
	servers = '',
	--=================== 以下可保持默认 ===================--


	---------------------- 提示缺失信息 ----------------------
	-- 是否提示缺失信息
	-- 0: 不提示
	-- 1: 仅"字体"缺失时提示
	-- 2: "字体"或"字形"缺失都提示
	-- 不管选哪个, 控制台都能查看全部信息
	reminder = 2,

	-- 提示方式
	-- true:  总是使用屏幕消息提示 (即使有 uosc)
	-- false:   有 uosc 则使用 uosc 菜单, 没有则通过屏幕消息提示
	always_osd = false,

	---------- 通过屏幕消息提示字体缺失时的按键设置 ----------
	---复制字体名称
	key_copy = 'Ctrl+c',

	-- 查看日志
	key_logs = 'f',

	-- 忽略提示, 继续播放
	key_close = 'SPACE',
}
------------------------------ 脚本配置结束 ------------------------------

local API_PATH = '/api/subset'
local LOG_PATH = '/fontinass/#/miss-logs'

local mp = require 'mp'
local utils = require 'mp.utils'
local osd = mp.create_osd_overlay('ass-events')
local platform = mp.get_property_native('platform')
require 'mp.options'.read_options(o, mp.get_script_name())

local API
local selected_server = 0		--当前使用的服务器
local servers = {}				--可以配置多个服务地址
local items, message = {}, ''	--再次打开缺失信息菜单时使用
local miss = '' 				--供复制到剪切板使用
local subsets = {}				--记录处理过的字幕, 防止重复处理
local uosc_version = nil		--检测uosc
local reloaded = false			--抵消切换子集化字幕触发的监测


local function switchServer()
	if selected_server == #servers then
		return false
	end

	selected_server = selected_server + 1
	API = servers[selected_server]
	return true
end


local function switchSubtitle(path, result)
	local subtitle = result.stdout:match("%[Script Info%].*")

	if not subtitle then
		mp.msg.error('响应中没有找到字幕内容')
		return false
	end

	local backup = path .. '.backup'
	local success, err = os.rename(path, backup)
	if not success then
		mp.msg.error('备份失败: ' .. (err or '未知错误'))
		return false
	end

	local out_file, err = io.open(path, "w")
	if not out_file then
		mp.msg.error('写入失败: ' .. (err or '未知错误'))
		os.rename(backup, path)
		return false
	end
	out_file:write(subtitle)
	out_file:close()

	reloaded = true
	mp.commandv("sub-reload")
	subsets[path] = 1
	return true
end


local function decode(data)
	if not data then return nil end
	-- 用来解码 x-message
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

	return utils.parse_json(result)
end


local function openMenu(first)
	-- 没处理过字幕
	if not next(subsets) then mp.osd_message('还没处理过本地字幕', 3) return end
	-- 没有缺失信息
	if not next(items) and message == '' then
		if not first then mp.osd_message('当前字幕没有缺失的字体或字形', 3) end
		return
	end

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

		-- 注册快捷键
		-- 快捷键1: 关闭消息
		mp.add_forced_key_binding(o.key_close, "temp_key_to_close", function()
			remove()
			mp.set_property_bool('pause', false)
		end)
		-- 快捷键2: 复制缺失信息
		mp.add_forced_key_binding(o.key_copy, "temp_key_to_copy", function()
			mp.commandv("run", "powershell", "set-clipboard", table.concat({'"', miss, '"'}))
			mp.osd_message('已复制')
		end)
		-- 快捷键3: 打开日志面板
		mp.add_forced_key_binding(o.key_logs, "temp_key_to_open_log", function()
			mp.commandv('script-binding', mp.get_script_name() .. '/openLog')
		end)

		-- 先清空再刷新osd, 防止连续加载字幕导致重叠
		osd:remove()
		osd.data = message
		osd:update()
	end
end


local function warn(miss)
	-- 分离字体和字形信息
	local zt, zx = {}, {}
	for _, line in ipairs(miss) do
		local prefix = line:match("^(.-)%s*%[")
		if string.find(prefix, "字体") or string.find(prefix, "font") then
			table.insert(zt, line:match("%[([^%]]+)%]"))
		elseif string.find(prefix, "字形") then
			table.insert(zx, line:match("%[.-%]")..'：'..line:match("%((.-)%)"))
		elseif string.find(prefix, "glyphs") then
			table.insert(zx, line:match("%[.*"))
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
	if uosc_version and not o.always_osd then
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

		table.insert(items, {
			title = '🔍 打开日志面板',
			align = 'center',
		})
	else
	-- osd 通知	
		-- 提前构建好osd消息, 后面可能会被快捷键调用, 不必反复构建
		if next(zt) then
			message = message .. '\\N\\N\\N{\\fs32\\c&H6B6BFF&}⚠️ 字体缺失\\N'
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

		tail = tail..string.format(
			'按 {\\c&H66D7FF&}%s{\\c&HEEEEEE&} 忽略并继续, '..
			'按 {\\c&H66D7FF&}%s{\\c&HEEEEEE&} 复制, '..
			'按 {\\c&H66D7FF&}%s{\\c&HEEEEEE&} 访问日志面板',
			o.key_close, o.key_copy, o.key_logs
		)

		message = head..message..tail
	end

	-- 安静模式 或 (仅字体缺失时通知, 且没有字体缺失) 不通知
	if o.reminder == 0 or (o.reminder == 1 and not next(zt)) then return end

	-- 发送通知
	openMenu(true)
end


local function post(path, retry_count)
	retry_count = retry_count or 0
	local max_retries = 2

	if o.reminder == 2 then
		if retry_count > 0  then
			mp.msg.warn(string.format('正在重试 (%d/%d)...', retry_count, max_retries))
		else
			mp.osd_message('⏳ 正在子集化字幕...', 30)
		end
	end

	-- 使用 mp.command_native_async 发送异步请求
	mp.command_native_async({
		name = "subprocess",
		args = {
			"curl", "-s", "-i",
			"-X", "POST",
			API,
			"--data-binary", "@" .. path,
			"--insecure",
			"--connect-timeout", "5",
			"--max-time", "30",
			"-H", "X-Clear-Fonts: 0",			-- 清除内嵌字体
			"-H", "X-Fonts-Check: 0",			-- 严格模式, 缺失字体便不处理
			},
		playback_only = false,
		capture_stdout = true,
		capture_stderr = true,
	}, function(success, result, error)
		-- 异步回调函数
		if not success then
			mp.msg.error('请求失败: ' .. (error or '未知错误'))
			mp.osd_message('❎ 请求失败', 3)
			return
		end

		-- 可重试的 curl 错误
		local retryable_curl_errors = {
			[6] = true, [7] = true, [28] = true,
			[52] = true, [56] = true,
		}

		-- 判断是否需要重试（还在重试次数内，且是临时性错误）
		if result.status ~= 0 and retryable_curl_errors[result.status] and retry_count < max_retries then
			mp.msg.warn(string.format('请求失败 (curl:%d)，%d秒后重试...',
				result.status, retry_count + 1))
			mp.add_timeout(retry_count + 1, function()
				post(path, retry_count + 1)
			end)
			return
		end

		-- 处理结果
		if result.status == 0 then
			local http_status = nil
			for code_str in result.stdout:gmatch("HTTP/%d%.%d (%d+)") do
				if code_str ~= '100' then
					http_status = code_str
					break
				end
			end
			local code = result.stdout:match("[Xx]%-[Cc]ode: ([^\r\n]*)")
			local xmessage = decode(result.stdout:match("[Xx]%-[Mm]essage: ([^\r\n]*)"))

			-- 处理不同的 HTTP 状态码
			local should_switch = false
			
			if http_status == '200' then
				-- HTTP 200 是成功的，根据 X-Code 判断具体结果
				if code == '200' then
					if switchSubtitle(path, result) then
						mp.msg.info('子集化完成')
						if o.reminder == 2 then
							mp.osd_message('✅ 子集化完成', 3)
						end
					end
				elseif code == '201' then
					if switchSubtitle(path, result) then
						mp.msg.warn('子集化完成')
						if o.reminder == 2 then
							mp.osd_message('✅ 子集化完成', 3)
						end
						if xmessage then
							warn(xmessage)
						end
					end
				elseif code == '400' then
					-- 业务逻辑错误（如字幕格式问题），不切换
					mp.msg.error('❎ 子集化失败: ' .. (xmessage or '未知错误'))
					mp.osd_message('❎ 子集化失败', 3)
				else
					-- X-Code 未知，可能是服务器版本不同，尝试切换
					mp.msg.error('❎ 未知响应: HTTP 200, X-Code: ' .. (code or '?'))
					if xmessage then
						mp.msg.error(utils.format_json(xmessage))
					end
					should_switch = true
				end
			elseif http_status then
				-- 所有非 200 的 HTTP 状态码都尝试切换服务器
				local status_msgs = {
					['403'] = '访问被拒绝',
					['404'] = '页面不存在',
					['405'] = '方法不允许',
					['500'] = '服务器内部错误',
					['502'] = '网关错误',
					['503'] = '服务不可用',
					['504'] = '网关超时',
				}
				local msg = status_msgs[http_status] or ('HTTP ' .. http_status)
				mp.msg.error(string.format('服务器返回错误 (%s): %s', API, msg))
				should_switch = true
			else
				-- 没有解析到 HTTP 状态码，异常情况
				mp.msg.error('无法解析服务器响应 (' .. API .. ')')
				should_switch = true
			end
			
			-- 处理服务器切换
			if should_switch then
				if switchServer() then
					mp.msg.info('切换到备用服务器: ' .. API)
					mp.osd_message('🔄 切换服务器...', 3)
					mp.add_timeout(0.5, function()
						post(path, 0)  -- 在新服务器上重新开始
					end)
				else
					mp.msg.error('所有服务器都不可用')
					mp.osd_message('❎ 所有服务器都不可用', 5)
				end
			end
		else
			-- curl连接错误（重试次数已用完，或者不可重试的错误）
			local errors = {
				[6] = '无法解析主机名',
				[7] = '无法连接到服务器',
				[28] = '连接超时',
				[35] = 'SSL错误',
				[52] = '服务器无响应',
			}
			local err_desc = errors[result.status] or ('curl错误: ' .. result.status)
			mp.msg.error('请求失败 (' .. API .. '): ' .. err_desc)
			
			-- 尝试切换到下一个服务器
			if switchServer() then
				mp.msg.info('切换到备用服务器: ' .. API)
				mp.osd_message('🔄 切换服务器...', 3)
				mp.add_timeout(0.5, function()
					post(path, 0)  -- 在新服务器上重新开始
				end)
			else
				-- 没有更多服务器可用
				mp.msg.error('所有服务器都不可用')
				mp.osd_message('❎ 所有服务器都不可用', 5)
			end
		end
	end)

	-- 不管处理成功与否, 都不重复处理同一个字幕, 防止在连续加载字幕时重复请求
	subsets[path] = 0
end


local function on_sub_changed(_, sub)
	-- 抵消加载子集化字幕的触发
	if reloaded then reloaded = false return end

	-- 更换字幕,清空旧字幕的缺失信息
	items, message, miss = {}, '', ''

	if not sub or not sub.external or sub.codec ~= "ass" or sub["external-filename"]:match('^http') then return end

	local external_filename = sub["external-filename"]:gsub("\\", "/")

	-- 当前视频没处理过字幕, 直接处理
	if not next(subsets) then
		post(external_filename)
	else
		-- 已经处理过一些字幕, 检查当前字幕是不是处理过的
		local found = false
		for item, _ in pairs(subsets) do
			if item == external_filename then
				found = true;
				break
			end
		end

		if found then	-- 处理过
			reloaded = true
			mp.commandv("sub-reload")
		else			--没处理过
			post(external_filename)
		end
	end
end


local function endFile()
	-- 视频结束删除临时生成的字幕, 恢复原字幕
	if next(subsets) then
		for item, value in pairs(subsets) do
			if value == 1 then
				local backup = item .. '.backup'
				if utils.file_info(backup) then
					os.remove(item)
					os.rename(backup, item)
				end
			end
		end
	end
	subsets = {}
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
	local link = API:gsub(string.format("%s$", API_PATH), LOG_PATH)
	local param = ""
	if platform == "windows" then
		param = 'no-osd run cmd /c start "" "' .. link .. '"'
	elseif platform == "darwin" then
		param = "no-osd run /bin/sh -c \"open '" .. link .. "' &\""
	elseif platform == "linux" then
		param = "no-osd run /bin/sh -c \"xdg-open '" .. link .. "' &\""
	else
		return
	end
	mp.command(param)
end


local function checkUosc()
	if o.always_osd then return end
	mp.register_script_message('uosc-version', function(version)
		uosc_version = version
		mp.unregister_script_message('uosc-version')
	end)
end


for url in o.servers:gmatch("[^,]+") do
    table.insert(servers, url)
end

if next(servers) then
	switchServer()
	checkUosc()
	mp.register_event('end-file', endFile)
	mp.observe_property('current-tracks/sub', 'native', on_sub_changed)
	mp.register_script_message('menu_event', menu_event)
	mp.add_key_binding(nil, 'openLog', openLog)
	mp.add_key_binding(nil, 'fonts', openMenu)
else
	mp.msg.error('请在脚本配置中设置 FontInAss 服务地址')
	mp.osd_message('请在脚本配置中设置 FontInAss 服务地址', 5)
end