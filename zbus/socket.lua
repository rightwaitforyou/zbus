local ev = require'ev'
local socket = require'socket'
require'pack'

local print = print
local pairs = pairs
local tinsert = table.insert
local tconcat = table.concat
local ipairs = ipairs
local assert = assert
local spack = string.pack
local log = print

module('zbus.socket')

local receive_message = 
   function(self)
      local parts = {}
      while true do
         local _,bytes = self:receive(4):unpack('>I')
         if bytes == 0 then 
            break
         end
         local part = self:receive(bytes)
         tinsert(parts,part)
      end
--      print('RECV',#parts,tconcat(parts))
      return parts
   end

local send_message = 
   function(self,parts)
      local message = ''
      for i,part in ipairs(parts) do
         local len = #part
         assert(len>0)
         message = message..spack('>I',len)..part
      end
      message = message..spack('>I',0)      
      self:send(message)
   end

local wrap = 
   function(sock)
      sock:settimeout(0)
      sock:setoption('tcp-nodelay',true)
      local on_message = function() end
      local on_close = function() end
      local wrapped = {}
      wrapped.send_message =                              
         function(_,parts)
--            assert(#parts>0)
--            print('SND',#parts,tconcat(parts))
            local message = ''
            for i,part in ipairs(parts) do
               message = message..spack('>I',#part)..part
            end
            message = message..spack('>I',0)
            local len = #message
            assert(len>0)
            local pos = 1
            ev.IO.new(
               function(loop,write_io)                                
                  while pos < len do
                     local err                                    
                     pos,err = sock:send(message,pos)
                     if not pos then
                        if err == 'timeout' then
                           return
                        elseif err == 'closed' then
                           write_io:stop(loop)
                           sock:shutdown()
                           sock:close()
                           return
                        end
                     end
                  end
                  write_io:stop(loop)
               end,
               sock:getfd(),
               ev.WRITE
            ):start(ev.Loop.default)
         end
      wrapped.on_close = 
         function(_,f)
            on_close = f
         end
      wrapped.on_message = 
         function(_,f)
            on_message = f
         end     
      wrapped.close =
         function()
            sock:shutdown()
            sock:close()
--            sock = nil
         end
      wrapped.read_io = 
         function()
            local parts = {}
            local part
            local left
            local length
            local header
            local _
            
            return ev.IO.new(
               function(loop,read_io)
                  while true do
                     if not header or #header < 4 then
                        local err,sub 
                        header,err,sub = sock:receive(4,header)
                        if err then
                           if err == 'timeout' then
                              header = sub
                              return                                    
                           else
                              if err ~= 'closed' then
                                 log('ERROR','unknown socket error',err)
                              end
                              read_io:stop(loop)
                              sock:shutdown()
                              sock:close()
                              on_close(wrapped)
                              return                           
                           end
                        end
                        if #header == 4 then
                           _,left = header:unpack('>I')
                           if left == 0 then
--                              print('on message',#parts,tconcat(parts))
                              on_message(parts,wrapped)
                              parts = {}
                              part = nil
                              left = nil
                              length = nil
                              header = nil
                           else
                              length = left
                           end
                        end
                     end
                     if length then
                        if not part or #part ~= length then
                           local err,sub
                           part,err,sub = sock:receive(length,part)
                           if err then
                              if err == 'timeout' then
                                 part = sub
                                 left = length - #part
                                 return
                              else 
                                 if err ~= 'closed' then
                                    log('ERROR','unknown socket error',err)
                                 end
                                 read_io:stop(loop)
                                 sock:shutdown()
                                 sock:close()
                                 on_close(wrapped)                                
                                 return
                              end
                           end
                           if #part == length then
                              tinsert(parts,part)
                              part = nil
                              left = nil
                              length = nil
                              header = nil
                           end
                        end
                     end -- if length
                  end -- while
               end,
         sock:getfd(),
         ev.READ)
         end
      return wrapped
   end



local listener = 
   function(port,on_connect)
      local sock = assert(socket.bind('*',port))
      sock:settimeout(0)
      local listen_io = ev.IO.new(
         function(loop,accept_io)
            local client = assert(sock:accept())         
            local wrapped = wrap(client)
            wrapped:read_io():start(loop)
            on_connect(wrapped)
         end,
         sock:getfd(),
         ev.READ)
      return {
         io = listen_io
      }
   end

return {
   listener = listener,
   wrap = wrap,
   send_message = send_message,
   receive_message = receive_message
}

