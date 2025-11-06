local mp = require 'mp'
local utils = require 'mp.utils'

local o = {
	--设置你的fontinass服务地址
    api = 'http://[ip]:[port]/fontinass/process_bytes',
	--安静模式,不提示字体缺失
	silent = false,
    --字体缺失日志文件路径,设置后可通过按键打开该文件所在位置
	--例如: C:/path/to/fontinass/logs/miss_logs.txt
    miss_logs_path = '',
	--打开日志文件的按键
	key = 'ENTER',
	--按键提示持续时间(秒)
	duration = 15,
	--子集化后字幕存放的临时文件夹,需手动创建好    ~~home 代表mpv配置目录
	--例如: '~~home/_cache/fontinass_subs'
    temp_dir = '~~home'
}

if o.temp_dir:match('^~~home') then
	o.temp_dir = mp.command_native({"expand-path", o.temp_dir})
end


local processing = false
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


function extractContent(text)
    local miss = text:match("error: ([^\\]*)")
    local startPos = text:find("%[Script Info%]")
    local subtitle = startPos and text:sub(startPos) or nil
    miss = decode(miss)
    return miss, subtitle
end


function tempBind(callback)
    local binding_name = "temp_key_to_open_log"
    mp.add_forced_key_binding(o.key, binding_name, function()
        mp.remove_key_binding(binding_name)
		mp.osd_message('')
        callback()
    end)
    mp.add_timeout(o.duration, function()
        pcall(mp.remove_key_binding, binding_name)
    end)
    mp.osd_message(string.format("字体缺失    按下 %s 查看日志", o.key), o.duration)
end


local function warn(miss)
	if not o.silent then
		if uosc_version then
			mp.set_property('pause', 'yes')
			local value = true
			local items = {}
			for line in miss:gmatch("([^\r\n]+)") do
				table.insert(items, {title = line:match("%[([^%]]+)%]"), hint = line:match("^(.-)%s*%[")})
			end
			local menu_props = utils.format_json({
				type = 'font-loss',
				title = '字体缺失',
				selected_index = 0,
				items = items,
				callback = {mp.get_script_name(), 'menu_event'},
				footnote = '点击以打开日志文件',})	
			mp.commandv('script-message-to', 'uosc', 'open-menu', menu_props)
		else
			local function osd()
				tempBind(function()
					mp.commandv('script-binding', mp.get_script_name() .. '/openLog' )
				end)
			end
			mp.add_timeout(1, osd)
		end
	end
	mp.msg.warn(miss)
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
		local miss, subtitle = extractContent(text)
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
		mp.msg.info('字幕字体子集化成功')
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
end


mp.register_event('file-loaded', on_file_loaded)
mp.register_event('end-file', delete)
mp.observe_property('sid', 'number', on_sub_changed)

mp.add_key_binding(nil, 'openLog', function()
	if o.miss_logs_path ~= '' then
		utils.subprocess_detached(
			{args = {'explorer', '/select,', o.miss_logs_path}, 
			cancellable = false})
	else
		mp.osd_message('未设置字体缺失日志文件路径', 5)
	end
end)

mp.register_script_message('uosc-version', function(version)
  uosc_version = version
end)

mp.register_script_message('menu_event', function(json)
	local event = utils.parse_json(json)
	if event.type == 'activate' then
		mp.commandv('script-binding', mp.get_script_name() .. '/openLog')
	elseif event.type == 'close' then
		mp.set_property('pause', 'no')
	end

end)
