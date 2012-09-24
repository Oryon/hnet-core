-- ex: set ro:
-- DO NOT EDIT.
-- generated by smc (http://smc.sourceforge.net/)
-- from file : skv.sm

local error = error
local pcall = pcall
local tostring = tostring
local strformat = require 'string'.format

local statemap = require 'statemap'

_ENV = nil

local SKVState = statemap.State.class()

local function _empty ()
end
SKVState.Entry = _empty
SKVState.Exit = _empty

local function _default (self, fsm)
    self:Default(fsm)
end
SKVState.BindFailed = _default
SKVState.Bound = _default
SKVState.ConnectFailed = _default
SKVState.Connected = _default
SKVState.ConnectionClosed = _default
SKVState.HaveUpdate = _default
SKVState.Initialized = _default
SKVState.ReceiveVersion = _default
SKVState.Timeout = _default

function SKVState:Default (fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("TRANSITION   : Default\n")
    end
    local msg = strformat("Undefined Transition\nState: %s\nTransition: %s\n",
                          fsm:getState().name,
                          fsm.transition)
    error(msg)
end

local Client = {}
local Server = {}
local Terminal = {}

Client.Default = SKVState:new('Client.Default', -1)

function Client.Default:HaveUpdate (fsm, k, v)
    local ctxt = fsm.owner
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Client.Default\n")
    end
    local endState = fsm:getState()
    if fsm.debugFlag then
        fsm.debugStream:write("ENTER TRANSITION: Client.Default:HaveUpdate(k=" .. tostring(k) .. ", v=" .. tostring(v) .. ")\n")
    end
    fsm:clearState()
    local r, msg = pcall(
        function ()
            ctxt:store_local_update(k, v)
        end
    )
    if fsm.debugFlag then
        fsm.debugStream:write("EXIT TRANSITION : Client.Default:HaveUpdate(k=" .. tostring(k) .. ", v=" .. tostring(v) .. ")\n")
    end
    fsm:setState(endState)
end

Client.Init = Client.Default:new('Client.Init', 0)

function Client.Init:Entry (fsm)
    local ctxt = fsm.owner
    ctxt:init_client()
end

function Client.Init:Initialized (fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Client.Init\n")
    end
    fsm:getState():Exit(fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("ENTER TRANSITION: Client.Init:Initialized()\n")
    end
    if fsm.debugFlag then
        fsm.debugStream:write("EXIT TRANSITION : Client.Init:Initialized()\n")
    end
    fsm:setState(Client.Connecting)
    fsm:getState():Entry(fsm)
end

Client.Connecting = Client.Default:new('Client.Connecting', 1)

function Client.Connecting:Entry (fsm)
    local ctxt = fsm.owner
    ctxt:connect()
end

function Client.Connecting:Exit (fsm)
    local ctxt = fsm.owner
    ctxt:clear_ev()
end

function Client.Connecting:ConnectFailed (fsm)
    local ctxt = fsm.owner
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Client.Connecting\n")
    end
    if  ctxt:is_long_lived()  then
        fsm:getState():Exit(fsm)
        if fsm.debugFlag then
            fsm.debugStream:write("ENTER TRANSITION: Client.Connecting:ConnectFailed()\n")
        end
        -- No actions.
        if fsm.debugFlag then
            fsm.debugStream:write("EXIT TRANSITION : Client.Connecting:ConnectFailed()\n")
        end
        fsm:setState(Server.Init)
        fsm:getState():Entry(fsm)
    else
        fsm:getState():Exit(fsm)
        if fsm.debugFlag then
            fsm.debugStream:write("ENTER TRANSITION: Client.Connecting:ConnectFailed()\n")
        end
        if fsm.debugFlag then
            fsm.debugStream:write("EXIT TRANSITION : Client.Connecting:ConnectFailed()\n")
        end
        fsm:setState(Terminal.ClientFailConnect)
        fsm:getState():Entry(fsm)
    end
end

function Client.Connecting:Connected (fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Client.Connecting\n")
    end
    fsm:getState():Exit(fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("ENTER TRANSITION: Client.Connecting:Connected()\n")
    end
    if fsm.debugFlag then
        fsm.debugStream:write("EXIT TRANSITION : Client.Connecting:Connected()\n")
    end
    fsm:setState(Client.WaitVersion)
    fsm:getState():Entry(fsm)
end

Client.WaitUpdates = Client.Default:new('Client.WaitUpdates', 2)

function Client.WaitUpdates:Entry (fsm)
    local ctxt = fsm.owner
    ctxt:send_local_state()
end

function Client.WaitUpdates:Exit (fsm)
    local ctxt = fsm.owner
    ctxt:clear_jsoncodec()
end

function Client.WaitUpdates:ConnectionClosed (fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Client.WaitUpdates\n")
    end
    fsm:getState():Exit(fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("ENTER TRANSITION: Client.WaitUpdates:ConnectionClosed()\n")
    end
    if fsm.debugFlag then
        fsm.debugStream:write("EXIT TRANSITION : Client.WaitUpdates:ConnectionClosed()\n")
    end
    fsm:setState(Client.Connecting)
    fsm:getState():Entry(fsm)
end

function Client.WaitUpdates:HaveUpdate (fsm, k, v)
    local ctxt = fsm.owner
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Client.WaitUpdates\n")
    end
    local endState = fsm:getState()
    if fsm.debugFlag then
        fsm.debugStream:write("ENTER TRANSITION: Client.WaitUpdates:HaveUpdate(k=" .. tostring(k) .. ", v=" .. tostring(v) .. ")\n")
    end
    fsm:clearState()
    local r, msg = pcall(
        function ()
            ctxt:store_local_update(k, v)
            ctxt:send_update(k, v)
        end
    )
    if fsm.debugFlag then
        fsm.debugStream:write("EXIT TRANSITION : Client.WaitUpdates:HaveUpdate(k=" .. tostring(k) .. ", v=" .. tostring(v) .. ")\n")
    end
    fsm:setState(endState)
end

Client.WaitVersion = Client.Default:new('Client.WaitVersion', 3)

function Client.WaitVersion:Entry (fsm)
    local ctxt = fsm.owner
    ctxt:wrap_socket_jsoncodec()
end

function Client.WaitVersion:ConnectionClosed (fsm)
    local ctxt = fsm.owner
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Client.WaitVersion\n")
    end
    fsm:getState():Exit(fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("ENTER TRANSITION: Client.WaitVersion:ConnectionClosed()\n")
    end
    fsm:clearState()
    local r, msg = pcall(
        function ()
            ctxt:clear_jsoncodec()
        end
    )
    if fsm.debugFlag then
        fsm.debugStream:write("EXIT TRANSITION : Client.WaitVersion:ConnectionClosed()\n")
    end
    fsm:setState(Client.Connecting)
    fsm:getState():Entry(fsm)
end

function Client.WaitVersion:ReceiveVersion (fsm, v)
    local ctxt = fsm.owner
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Client.WaitVersion\n")
    end
    if ctxt:protocol_is_current_version(v) then
        fsm:getState():Exit(fsm)
        if fsm.debugFlag then
            fsm.debugStream:write("ENTER TRANSITION: Client.WaitVersion:ReceiveVersion(v=" .. tostring(v) .. ")\n")
        end
        -- No actions.
        if fsm.debugFlag then
            fsm.debugStream:write("EXIT TRANSITION : Client.WaitVersion:ReceiveVersion(v=" .. tostring(v) .. ")\n")
        end
        fsm:setState(Client.WaitUpdates)
        fsm:getState():Entry(fsm)
    else
        fsm:getState():Exit(fsm)
        if fsm.debugFlag then
            fsm.debugStream:write("ENTER TRANSITION: Client.WaitVersion:ReceiveVersion(v=" .. tostring(v) .. ")\n")
        end
        if fsm.debugFlag then
            fsm.debugStream:write("EXIT TRANSITION : Client.WaitVersion:ReceiveVersion(v=" .. tostring(v) .. ")\n")
        end
        fsm:setState(Terminal.ClientFailConnect)
        fsm:getState():Entry(fsm)
    end
end

Server.Default = SKVState:new('Server.Default', -1)

function Server.Default:HaveUpdate (fsm, k, v)
    local ctxt = fsm.owner
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Server.Default\n")
    end
    local endState = fsm:getState()
    if fsm.debugFlag then
        fsm.debugStream:write("ENTER TRANSITION: Server.Default:HaveUpdate(k=" .. tostring(k) .. ", v=" .. tostring(v) .. ")\n")
    end
    fsm:clearState()
    local r, msg = pcall(
        function ()
            ctxt:store_local_update(k, v)
        end
    )
    if fsm.debugFlag then
        fsm.debugStream:write("EXIT TRANSITION : Server.Default:HaveUpdate(k=" .. tostring(k) .. ", v=" .. tostring(v) .. ")\n")
    end
    fsm:setState(endState)
end

Server.Init = Server.Default:new('Server.Init', 0)

function Server.Init:Entry (fsm)
    local ctxt = fsm.owner
    ctxt:init_server()
end

function Server.Init:Initialized (fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Server.Init\n")
    end
    fsm:getState():Exit(fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("ENTER TRANSITION: Server.Init:Initialized()\n")
    end
    if fsm.debugFlag then
        fsm.debugStream:write("EXIT TRANSITION : Server.Init:Initialized()\n")
    end
    fsm:setState(Server.Binding)
    fsm:getState():Entry(fsm)
end

Server.Binding = Server.Default:new('Server.Binding', 1)

function Server.Binding:Entry (fsm)
    local ctxt = fsm.owner
    ctxt:bind()
end

function Server.Binding:BindFailed (fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Server.Binding\n")
    end
    fsm:getState():Exit(fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("ENTER TRANSITION: Server.Binding:BindFailed()\n")
    end
    if fsm.debugFlag then
        fsm.debugStream:write("EXIT TRANSITION : Server.Binding:BindFailed()\n")
    end
    fsm:setState(Server.InitWaitTimeout)
    fsm:getState():Entry(fsm)
end

function Server.Binding:Bound (fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Server.Binding\n")
    end
    fsm:getState():Exit(fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("ENTER TRANSITION: Server.Binding:Bound()\n")
    end
    if fsm.debugFlag then
        fsm.debugStream:write("EXIT TRANSITION : Server.Binding:Bound()\n")
    end
    fsm:setState(Server.WaitConnections)
    fsm:getState():Entry(fsm)
end

Server.InitWaitTimeout = Server.Default:new('Server.InitWaitTimeout', 2)

function Server.InitWaitTimeout:Entry (fsm)
    local ctxt = fsm.owner
    ctxt:increase_retry_timer()
    ctxt:start_retry_timer()
end

function Server.InitWaitTimeout:Timeout (fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("LEAVING STATE   : Server.InitWaitTimeout\n")
    end
    fsm:getState():Exit(fsm)
    if fsm.debugFlag then
        fsm.debugStream:write("ENTER TRANSITION: Server.InitWaitTimeout:Timeout()\n")
    end
    if fsm.debugFlag then
        fsm.debugStream:write("EXIT TRANSITION : Server.InitWaitTimeout:Timeout()\n")
    end
    fsm:setState(Client.Connecting)
    fsm:getState():Entry(fsm)
end

Server.WaitConnections = Server.Default:new('Server.WaitConnections', 3)

Terminal.Default = SKVState:new('Terminal.Default', -1)

Terminal.ClientFailConnect = Terminal.Default:new('Terminal.ClientFailConnect', 0)

function Terminal.ClientFailConnect:Entry (fsm)
    local ctxt = fsm.owner
    ctxt:fail("unable to connect to SKV")
end

local skvContext = statemap.FSMContext.class()

function skvContext:_init ()
    self:setState(Client.Init)
end

function skvContext:BindFailed ()
    self.transition = 'BindFailed'
    self:getState():BindFailed(self)
    self.transition = nil
end

function skvContext:Bound ()
    self.transition = 'Bound'
    self:getState():Bound(self)
    self.transition = nil
end

function skvContext:ConnectFailed ()
    self.transition = 'ConnectFailed'
    self:getState():ConnectFailed(self)
    self.transition = nil
end

function skvContext:Connected ()
    self.transition = 'Connected'
    self:getState():Connected(self)
    self.transition = nil
end

function skvContext:ConnectionClosed ()
    self.transition = 'ConnectionClosed'
    self:getState():ConnectionClosed(self)
    self.transition = nil
end

function skvContext:HaveUpdate (...)
    self.transition = 'HaveUpdate'
    self:getState():HaveUpdate(self, ...)
    self.transition = nil
end

function skvContext:Initialized ()
    self.transition = 'Initialized'
    self:getState():Initialized(self)
    self.transition = nil
end

function skvContext:ReceiveVersion (...)
    self.transition = 'ReceiveVersion'
    self:getState():ReceiveVersion(self, ...)
    self.transition = nil
end

function skvContext:Timeout ()
    self.transition = 'Timeout'
    self:getState():Timeout(self)
    self.transition = nil
end

function skvContext:enterStartState ()
    self:getState():Entry(self)
end

return 
skvContext
-- Local variables:
--  buffer-read-only: t
-- End:
