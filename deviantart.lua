local urlparse = require("socket.url")
local http = require("socket.http")
local https = require("ssl.https")
local cjson = require("cjson")
local utf8 = require("utf8")

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = tonumber(os.getenv("concurrency"))
local item_type = nil
local item_name = nil
local item_value = nil
local item_user = nil

local url_count = 0
local tries = 0
local downloaded = {}
local seen_200 = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false

local discovered_outlinks = {}
local discovered_items = {}
local bad_items = {}
local ids = {}

local thread_counts = {}

local retry_url = false
local is_initial_url = true
local is_new_design = false
local offset_jumps = {}

abort_item = function(item)
  abortgrab = true
  --killgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if not target[item] then
--print('discovered', item)
    target[item] = true
    return true
  end
  return false
end

find_item = function(url)
  local value = nil
  local type_ = nil
  for pattern, name in pairs({
    ["^https?://[^/]*deviantart.com/global/difi/%?c%%5B%%5D=%%22GrusersModules%%22%%2C%%22findAndDisplayModule%%22%%2C%%5B%%22([0-9]+)%%22%%2C%%22frontroom%%22%%2C%%22joinrequest%%22%%2C%%22generic%%22%%2C%%7B%%7D%%5D"]="group",
    ["^https?://([^/]*deviantart%.net/.+)$"]="asset",
    ["^https?://([^/]*wixmp%.com/.+)$"]="asset",
    ["^https?://([^/]*deviantart%.com/[^/]+/blog.*[%?&]offset=.+)$"]="offset",
    ["^https?://([^/]*deviantart%.com/[^/]+/favourites/[0-9]+/.+[%?&]offset=.+)$"]="offset",
    ["^https?://([^/]*deviantart%.com/[^/]+/gallery/[0-9]+/.+[%?&]offset=.+)$"]="offset"
  }) do
    value = string.match(url, pattern)
    type_ = name
    if value then
      break
    end
  end
  if value and type_ then
    return {
      ["value"]=value,
      ["type"]=type_
    }
  end
end

set_item = function(url)
  found = find_item(url)
  if found then
    item_type = found["type"]
    item_value = found["value"]
    item_name_new = item_type .. ":" .. item_value
    if item_name_new ~= item_name then
      ids = {}
      ids[item_value] = true
      abortgrab = false
      tries = 0
      retry_url = false
      is_initial_url = true
      is_new_design = false
      item_name = item_name_new
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url, parenturl)
  if ids[url] then
    return true
  end
  
  if string.match(url, "^https?://[^/]*deviantart%.com/comments/")
    or string.match(url, "^https?://[^/]*deviantart%.com/[^/]+/journal/[^/]-%-[0-9]+$")
    --or string.match(url, "^https?://[^/]*deviantart%.com/[^/]+/gallery/.+%?set=[0-9]+$")
    or string.match(url, "^https?://[^/]*deviantart%.com/tag/")
    or string.match(url, "[%?&]page=")
    or string.match(url, "[%?&]order=") then
    return false
  end
  
  if not string.match(url, "/favourites/")
    and not string.match(url, "/gallery/")
    and not string.match(url, "https?://[^/]+/[^/]+/[^/]+/[^/]+$")
    and string.match(url, "[%?&]offset=[0-9]+") then
    return false
  end

  local skip = false
  for pattern, type_ in pairs({
    ["^https?://([^/]*deviantart%.net/.+)$"]="asset",
    ["^https?://([^/]*wixmp%.com/.+)$"]="asset",
    ["^https?://([^/]*deviantart%.com/[^/]+/blog.*[%?&]offset=.+)$"]="offset",
    ["^https?://([^/]*deviantart%.com/[^/]+/favourites/[0-9]+/.+[%?&]offset=.+)$"]="offset",
    ["^https?://([^/]*deviantart%.com/[^/]+/gallery/[0-9]+/.+[%?&]offset=.+)$"]="offset"
  }) do
    match = string.match(url, pattern)
    if match then
      local new_item = type_ .. ":" .. match
      if new_item ~= item_name then
        if type_ == "offset" then
          local a, offset_max, b = string.match(match, "^(.+[%?&]offset=)([0-9]+)(.*)$")
          local base = string.match(a, "^([^%?]+)")
          offset_jump = offset_jumps[base]
          if offset_jump
            and parenturl
            and base == string.match(parenturl, "^https?://([^%?]+)") then
            offset_max = tonumber(offset_max)
            local offset_i = offset_max
            local count = 0
            while discover_item(discovered_items, "offset:" .. a .. tostring(offset_i) .. b) do
              count = count + 1
              offset_i = offset_i - offset_jump
              if offset_i < 0 then
                break
              end
            end
          end
          skip = true
        else
          discover_item(discovered_items, new_item)
        end
      end
    end
  end
  if skip then
    return false
  end
  
  if not string.match(url, "^https?://[^/]*deviantart%.com/")
    and not string.match(url, "^https?://[^/]*deviantart%.net/")
    and not string.match(url, "^https?://[^/]*wixmp%.com/") then
    discover_item(discovered_outlinks, url)
  end

  for _, pattern in pairs({
    "([0-9]+)",
    "%%[0-9][0-9]([0-9]+)",
    "([^%?&;/]+)"
  }) do
    for s in string.gmatch(url, pattern) do
      if ids[string.lower(s)] then
        return true
      end
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  local html = urlpos["link_expect_html"]

  if allowed(url, parent["url"])
    and not processed(url)
    and string.match(url, "^https://")
    and not addedtolist[url] then
    addedtolist[url] = true
    return true
  end

  return false
end

decode_codepoint = function(newurl)
  newurl = string.gsub(
    newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
    function (s)
      return utf8.char(tonumber(s, 16))
    end
  )
  return newurl
end

percent_encode_url = function(newurl)
  result = string.gsub(
    newurl, "(.)",
    function (s)
      local b = string.byte(s)
      if b < 32 or b > 126 then
        return string.format("%%%02X", b)
      end
      return s
    end
  )
  return result
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  local json = nil
  
  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function fix_case(newurl)
    if not newurl then
      newurl = ""
    end
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl)
    if not newurl then
      newurl = ""
    end
    local first_url, rest = string.match(newurl, "^(.-)%s[0-9]+[a-z],(.+)$")
    if first_url and rest then
      check(rest)
      return check(first_url)
    end
    if string.match(newurl, "^https?://[^/]*wixmp%.com/") then
      return nil
    end
    newurl = decode_codepoint(newurl)
    newurl = fix_case(newurl)
    local origurl = url
    if string.len(url) == 0 or string.len(newurl) == 0 then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = string.match(url, "^(.-)[%.\\]*$")
    while string.find(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    if not processed(url_)
      and not processed(url_ .. "/")
      and allowed(url_, origurl) then
      table.insert(urls, {
        url=url_
      })
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function set_new_params(newurl, data)
    for param, value in pairs(data) do
      if value == nil then
        value = ""
      elseif type(value) == "string" then
        value = "=" .. value
      end
      if string.match(newurl, "[%?&]" .. param .. "[=&]") then
        newurl = string.gsub(newurl, "([%?&]" .. param .. ")=?[^%?&;]*", "%1" .. value)
      else
        if string.match(newurl, "%?") then
          newurl = newurl .. "&"
        else
          newurl = newurl .. "?"
        end
        newurl = newurl .. param .. value
      end
    end
    return newurl
  end

  local function increment_param(newurl, param, default, step)
    local value = string.match(newurl, "[%?&]" .. param .. "=([0-9]+)")
    if value then
      value = tonumber(value)
      value = value + step
      return check_new_params(newurl, param, tostring(value))
    else
      return check_new_params(newurl, param, default)
    end
  end

  local function flatten_json(json)
    local result = ""
    for k, v in pairs(json) do
      result = result .. " " .. k
      local type_v = type(v)
      if type_v == "string" then
        v = string.gsub(v, "\\", "")
        result = result .. " " .. v .. ' "' .. v .. '"'
      elseif type_v == "table" then
        result = result .. " " .. flatten_json(v)
      end
    end
    return result
  end
  
  local function get_call(data)
    local call = nil
    for _, data in pairs(json["DiFi"]["response"]["calls"]) do
      if call then
        error()
      end
      call = data
    end
    return call
  end

  if allowed(url)
    and status_code < 300
    and item_type ~= "asset" then
    html = read_file(file)
    if string.match(url, "^https?://[^/]*deviantart%.com/global/difi") then
      json = cjson.decode(html)
      local unescaped = urlparse.unescape(url)
      local call = get_call(json)
      if call["response"]["status"] ~= "SUCCESS" then
        return urls
      end
      local innerhtml = call["response"]["content"]["html"]
      if string.match(unescaped, '"GrusersModules","findAndDisplayModule"') then
        local groupname = string.match(innerhtml, 'gmi%-gruser_name="([^"]+)"')
        ids[string.lower(groupname)] = true
        check("https://www.deviantart.com/" .. groupname)
      elseif string.match(unescaped, '{"affiliates_offset":"[0-9]+"}') then
        local current_offset = string.match(unescaped, '{"affiliates_offset":"([0-9]+)"}')
        local new_offset = string.match(innerhtml, 'data%-offset="([0-9]+)"')
        if new_offset then
          local newurl = string.gsub(url, "(%%22affiliates_offset%%22%%3A%%22)[0-9]+(%%22)", "%1" .. new_offset .. "%2")
          assert(string.match(urlparse.unescape(newurl), '{"affiliates_offset":"' .. new_offset .. '"}'))
          check(newurl)
        end
      end
    end
    for affiliates_module in string.gmatch(html, "<div%s+id='affiliates_module_([0-9]+)'") do
      check("https://www.deviantart.com/global/difi/?c%5B%5D=%22GrusersModules%22%2C%22displayModule%22%2C%5B%2213573957%22%2C%22" .. affiliates_module .. "%22%2C%22generic%22%2C%7B%22affiliates_offset%22%3A%220%22%7D%5D&iid=0&mp=1&t=json")
    end
    
    if string.match(html, "^%s*{") then
      if not json then
        json = cjson.decode(html)
      end
      html = html .. flatten_json(json)
    end
    for newurl in string.gmatch(html, 'src="(https?://[^"/]+wixmp%.com/[^"]+)"') do
      allowed(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      if not string.match(url, "[%?&]offset=") then
        local base, offset = string.match(newurl, "^https?://([^%?]+).*[%?&]offset=([0-9]+)")
        offset = tonumber(offset)
        if base and offset and offset > 0
          and base == string.match(url, "^https?://([^%?]+)")
          and (
            not offset_jumps[base]
            or offset < offset_jumps[base]
          ) then
          offset_jumps[base] = offset
        end
      end
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
    if not string.match(url, "%.mpd$") then
      html = string.gsub(html, "&gt;", ">")
      html = string.gsub(html, "&lt;", "<")
      for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
        checknewurl(newurl)
      end
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()
  logged_response = true
  if not item_name then
    error("No item name found.")
  end
  is_initial_url = false
  is_new_design = false
  if string.match(url["url"], "^https?://[^/]*deviantart%.com/global/difi") then
    local html = read_file(http_stat["local_file"])
    if not (
        string.match(html, "^%s*{")
        and string.match(html, "}%s*$")
      ) then
      print("Did not get JSON data.")
      retry_url = true
      return false
    end
    local json = cjson.decode(percent_encode_url(decode_codepoint(html)))
    if json["DiFi"]["status"] ~= "SUCCESS" then
      print("DiFi response unsuccesful.")
      retry_url = true
      return false
    end
    for _, call in pairs(json["DiFi"]["response"]["calls"]) do
      if call["response"]["status"] ~= "SUCCESS" then
        print("One or more calls returned a bad result.")
        local error_message = call["response"]["content"]["error"]
        if error_message ~= "Couldn't find module: joinrequest"
          and error_message ~= "No such gruser" then
          abort_item()
          retry_url = true
        end
        return false
      end
    end
  elseif string.match(url["url"], "^https?://www%.deviantart%.com/") then
    local html = read_file(http_stat["local_file"])
    if string.match(html, '<a%s+href="https?://www%.deviantart%.com/community">Community</a> Group for the latest updates and activities%.') then
      print("Got the new design")
      is_new_design = true
      return false
    end
  end
  if http_stat["statcode"] ~= 200
    and http_stat["statcode"] ~= 301
    and http_stat["statcode"] ~= 404 then
    retry_url = true
    return false
  end
  if abortgrab then
    print("Not writing to WARC.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]
  
  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end
  
  if is_new_design then
    return wget.actions.EXIT
  end

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  if seen_200[url["url"]] then
    print("Received data incomplete.")
    abort_item()
    return wget.actions.EXIT
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  if status_code == 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 8
    if status_code == 404 then
      maxtries = 0
    end
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    if status_code == 200 then
      seen_200[url["url"]] = true
    end
    downloaded[url["url"]] = true
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 5
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = http.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["deviantart-dimjcpc1g4vonm8u"] = discovered_items,
    ["urls-fx8zdet5bt0erac4"] = discovered_outlinks
  }) do
    print('queuing for', string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 1000 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end


