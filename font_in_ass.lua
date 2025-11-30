--[[    https://github.com/Koopex/FontInAss_mpv-script

脚本功能: 请求 FontInAss 子集化处理本地 ass 字幕

------------------------------ 可用的快捷键 ------------------------------
#	script-binding font_in_ass/fonts  		#! 字体缺失列表
#	script-binding font_in_ass/openLog  	#! 打开字体缺失日志
]]

-------------------------------- 脚本配置 --------------------------------
local o = {
	-- 设置你的FontInAss服务地址, 使用 8011 端口
	-- 示例 'http://192.168.1.100:8011/fontinass/process_bytes'
    api = 'http://192.168.1.100:8011/fontinass/process_bytes',
	-- api 必须配置, 其他可选

	-- 安静模式,不提示字体缺失
	silent = false,
    -- FontInAss 的日志路径,设置后可通过按键打开该文件所在位置
	-- 可以留空: [[]] 但不能注释掉
	-- 示例: [[/path/to/fontinass/logs/miss_logs.txt]]
    miss_logs_path = [[]],

	-- 如果有 uosc,通过 uosc 菜单提示缺失的字体, 没有 uosc 则通过 osd 提示
	---------------------------------------------------------------------- 
	-- 即使有 uosc 也使用 osd 提示
	always_osd = false,
	-- osd 提示时, 复制字体名称的按键
	key_copy = 'Ctrl+c',
	-- osd 提示时, 查看日志的按键
	key_logs = 'f',
	-- osd 提示时, 关闭提示的按键
	key_close = 'ESC',
	-- osd 提示持续时间(秒)
	duration = 20,
	-- 子集化后字幕临时存放的文件夹, 播放结束自动删除字幕
	-- 如果需要更改, 必须提前创建好文件夹
	-- 示例: '~~home/_cache/fontinass_subs'  
	-- ~~home 代表mpv配置目录
    temp_dir = '~~home'
}
------------------------------ 脚本配置结束 ------------------------------



local mp = require 'mp'
local utils = require 'mp.utils'
if o.temp_dir:match('^~~home') then
	o.temp_dir = mp.command_native({"expand-path", o.temp_dir})
end


local processing = false
local items, message = {}, ''
local miss = ''
local subs = {}
local uosc_version = nil

local function decode(data)
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


local function extractContent(text)
    local miss = text:match("error: ([^\\]*)")
    local startPos = text:find("%[Script Info%]")
    local subtitle = startPos and text:sub(startPos) or nil
    miss = decode(miss)
    return miss, subtitle
end


local function openMenu(callback)
	if uosc_version then
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
		if message == '' then 
			mp.osd_message('未缺失')
			return 
		end
		osd = mp.create_osd_overlay('ass-events')
		if callback then
			callback()
		else
			local function remove()
				mp.remove_key_binding("temp_key_to_open_log")
				mp.remove_key_binding("temp_key_to_close")
				mp.remove_key_binding("temp_key_to_copy")
				osd:remove()
				timer:kill()
			end
			if o.miss_logs_path ~= '' then
				mp.add_forced_key_binding(o.key_logs, "temp_key_to_open_log", function()
					remove()
					mp.set_property_bool('pause', true)
					mp.commandv('script-binding', mp.get_script_name() .. '/openLog' )
				end)
			end
			mp.add_forced_key_binding(o.key_close, "temp_key_to_close", function()
				remove()
			end)
			mp.add_forced_key_binding(o.key_copy, "temp_key_to_copy", function()
				mp.set_property_bool('pause', true)
				mp.commandv("run", "powershell", "set-clipboard", table.concat({'"', miss, '"'}))
				remove()
			end)
			local head = '{\\fs30\\b1\\c&HFFFFFF&}'
			if o.miss_logs_path ~= '' then
				head = head .. string.format(
					'按 %s 关闭, 按 %s 复制, 按 %s 打开日志\\N\\N', 
					o.key_close, o.key_copy, o.key_logs
				)
			else
				head = head .. string.format(
					'按 %s 关闭, 按 %s 复制\\N\\N', 
					o.key_close, o.key_copy
				)
			end
			osd.data = head..message
			osd:update()
		end
	end
end


local function warn(miss)
	local zt, zx = {}, {}
	for line in miss:gmatch("([^\r\n]+)") do
		if string.find(line:match("^(.-)%s*%["), "字体") then
			table.insert(zt, line:match("%[([^%]]+)%]"))
		else
			table.insert(zx, line:match("%[([^%]]+)%]")..'：'..line:match("%](.*)"))
		end
	end
	if not o.silent then
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
			openMenu()
		else
			if next(zt) then
				message = message .. '{\\fs28\\b1\\c&H6B6BFF&}⚠️ 字体缺失\\N'
				for _, s in ipairs(zt) do
					message = message .. '{\\fs26\\b1\\c&HFFFFFF&}• ' .. s .. '\\N'
				end
				message = message .. '\\N'
			end
			if next(zx) then
				message = message .. '{\\fs28\\b1\\c&H3DD9FF&}📝 缺少字形\\N'
				for _, s in ipairs(zx) do
					message = message .. '{\\fs26\\b1\\c&HFFFFFF&}• ' .. s .. '\\N'
				end
			end
			openMenu(function()
				local seconds = o.duration
				timer = mp.add_periodic_timer(1, function()
					local head = '{\\fs30\\b1\\c&HFFFFFF&}'
					if o.miss_logs_path ~= '' then
						head = head .. string.format(
							'按 %s 关闭, 按 %s 复制, 按 %s 打开日志 ...... %d\\N\\N', 
							o.key_close, o.key_copy, o.key_logs, seconds
						)
					else
						head = head .. string.format(
							'按 %s 关闭, 按 %s 复制 ...... %d\\N\\N', 
							o.key_close, o.key_copy, seconds
						)
					end
					osd.data = head..message
					osd:update()
					seconds = seconds - 1
					if seconds <= 0 then
						pcall(mp.remove_key_binding, "temp_key_to_open_log")
						pcall(mp.remove_key_binding, "temp_key_to_close")
						pcall(mp.remove_key_binding, "temp_key_to_copy")
						osd:remove()
						timer:kill()
					end
				end, true)
				local function remove()
					mp.remove_key_binding("temp_key_to_open_log")
					mp.remove_key_binding("temp_key_to_close")
					mp.remove_key_binding("temp_key_to_copy")
					osd:remove()
					timer:kill()
				end
				if o.miss_logs_path ~= '' then
					mp.add_forced_key_binding(o.key_logs, "temp_key_to_open_log", function()
						remove()
						mp.set_property_bool('pause', true)
						mp.commandv('script-binding', mp.get_script_name() .. '/openLog' )
					end)
				end
				mp.add_forced_key_binding(o.key_close, "temp_key_to_close", function()
					remove()
				end)
				mp.add_forced_key_binding(o.key_copy, "temp_key_to_copy", function()
					mp.set_property_bool('pause', true)
					mp.commandv("run", "powershell", "set-clipboard", table.concat({'"', miss, '"'}))
					remove()
				end)
				timer:resume()
			end)
		end
	end
	for _, font in ipairs(zt) do
		mp.msg.error('字体缺失：'..font)
	end
	for _, font in ipairs(zx) do
		mp.msg.warn('缺少字形：'..font)
	end
end


local function post(sid, path)
	processing = true
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
		result = result.stdout
		local text = utils.format_json(result)
		local subtitle
		miss, subtitle = extractContent(text)
		subtitle = '["' .. subtitle .. ']'
		subtitle = utils.parse_json(subtitle)[1]
		local _, filename = utils.split_path(path)
		local temp_file = utils.join_path(o.temp_dir, filename)
		local out_file = io.open(temp_file, "w"):write(subtitle):close()
		mp.commandv("sub-remove", sid)
		mp.commandv("sub-add", temp_file, "select")
		table.insert(subs, temp_file)		
		mp.add_timeout(0.1, function()
			processing = false
		end)
		if miss~= '' then warn(miss) end
		mp.msg.info('子集化完成')
	end
end


local function getPath(sid)
	local track_list = mp.get_property_native("track-list", {})
    for _, track in ipairs(track_list) do
        if track.type == "sub" and track.id == sid then
            if track.external and track.codec == "ass" then
                local sub_path = track["external-filename"]
				if not sub_path:match('^http') then
					return sub_path:gsub("\\", "/")
				end
            end
            break
        end
    end
end


local function process(sid)
	local path = getPath(sid)
	if path then
		if not next(subs) then
			post(sid, path)
		else
			local found = false
			for _, item in ipairs(subs) do
				if item == path then
					found = true;
					break
				end
			end
			if not found then
				post(sid, path)
			end
		end
	end
end


local function on_sub_changed(name, value)
	if not processing and value and value > 0 then
		items, message, subs, miss = {}, '', {} ,''
		process(value)
	end
end


local function on_file_loaded()
	local sid = mp.get_property_number("sid")
	on_sub_changed(_, sid)
end


local function delete()
	if next(subs) then
		for _, s in ipairs(subs) do
			os.remove(s)
		end
	end
	items, message, subs, miss = {}, '', {} ,''
end


if not o.always_osd then
	mp.register_script_message('uosc-version', function(version)
	uosc_version = version
	mp.unregister_script_message('uosc-version')
	end)
end

mp.register_event('file-loaded', on_file_loaded)
mp.register_event('end-file', delete)
mp.observe_property('sid', 'number', on_sub_changed)

mp.register_script_message('menu_event', function(json)
	local event = utils.parse_json(json)
	if event.type == 'activate' then
		if event.value then
			mp.osd_message('已复制', 2)
			mp.commandv("run", "powershell", "set-clipboard", table.concat({'"', event.value, '"'}))
		else
			mp.commandv('script-binding', mp.get_script_name() .. '/openLog')
		end
	elseif event.type == 'close' then
		mp.set_property('pause', 'no')
	end
end)

mp.add_key_binding(nil, 'openLog', function()
	if o.miss_logs_path ~= '' then
		utils.subprocess_detached(
			{args = {'explorer', '/select,', o.miss_logs_path}, 
			cancellable = false})
	else
		mp.osd_message('未设置字体缺失日志文件路径', 5)
	end
end)

mp.add_key_binding(nil, 'fonts', openMenu)
