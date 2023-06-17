local jobs = require("overseer.strategy._jobs")
local shell = require("overseer.shell")
local util = require("overseer.util")

local terminal = require("toggleterm.terminal")

local ToggleTermStrategy = {}

---Run tasks using the toggleterm plugin
---@param opts nil|table
---    use_shell nil|boolean load user shell before running task
---    direction nil|"vertical"|"horizontal"|"tab"|"float"
---    highlights nil|table map to a highlight group name and a table of it's values
---    auto_scroll nil|boolean automatically scroll to the bottom on task output
---    close_on_exit nil|boolean close the terminal and delete terminal buffer (if open) after task exits
---    quit_on_exit "never"|"always"|"success" close the terminal window (if open) after task exits
---    open_on_start nil|boolean toggle open the terminal automatically when task starts
---    hidden nil|boolean cannot be toggled with normal ToggleTerm commands
---    on_create nil|fun(term: table) function to execute on terminal creation
---@return overseer.Strategy
function ToggleTermStrategy.new(opts)
  opts = vim.tbl_extend("keep", opts or {}, {
    use_shell = false,
    direction = nil,
    highlights = nil,
    auto_scroll = nil,
    close_on_exit = false,
    quit_on_exit = "never",
    open_on_start = true,
    hidden = false,
    on_create = nil,
  })
  return setmetatable({
    bufnr = nil,
    chan_id = nil,
    opts = opts,
    term = nil,
  }, { __index = ToggleTermStrategy })
end

function ToggleTermStrategy:reset()
  util.soft_delete_buf(self.bufnr)
  self.bufnr = nil
  if self.chan_id then
    vim.fn.jobstop(self.chan_id)
    self.chan_id = nil
  end
  if self.term then
    self.term:close()
  end
end

function ToggleTermStrategy:get_bufnr()
  return self.bufnr
end

---@param task overseer.Task
function ToggleTermStrategy:start(task)
  local chan_id
  local mode = vim.api.nvim_get_mode().mode
  local stdout_iter = util.get_stdout_line_iter()

  local function on_stdout(data)
    task:dispatch("on_output", data)
    local lines = stdout_iter(data)
    if not vim.tbl_isempty(lines) then
      task:dispatch("on_output_lines", lines)
    end
  end

  local cmd = task.cmd
  if type(cmd) == "table" then
    cmd = shell.escape_cmd(cmd, "strong")
  end

  local passed_cmd
  if not self.opts.use_shell then
    passed_cmd = cmd
  end

  self.term = terminal.Terminal:new({
    cmd = passed_cmd,
    env = task.env,
    highlights = self.opts.highlights,
    dir = task.cwd,
    direction = self.opts.direction,
    auto_scroll = self.opts.auto_scroll,
    close_on_exit = self.opts.close_on_exit,
    hidden = self.opts.hidden,
    on_create = function(t)
      if self.opts.on_create then
        self.opts.on_create(t)
      end

      if self.opts.use_shell then
        t:send(cmd)
        t:send("exit $?")
      end
    end,
    on_stdout = function(_job, job_id, d)
      if self.chan_id ~= job_id then
        return
      end
      on_stdout(d)
    end,
    on_exit = function(t, j, c)
      jobs.unregister(j)
      if self.chan_id ~= j then
        return
      end
      -- Feed one last line end to flush the output
      on_stdout({ "" })
      self.chan_id = nil
      if vim.v.exiting == vim.NIL then
        task:on_exit(c)
      end

      local close = self.opts.quit_on_exit == "always"
      close = close or (self.opts.quit_on_exit == "success" and c == 0)
      if close then
        t:close()
      end
    end,
  })

  if self.opts.open_on_start then
    self.term:toggle()
  else
    self.term:spawn()
  end

  chan_id = self.term.job_id
  self.bufnr = self.term.bufnr

  util.hack_around_termopen_autocmd(mode)

  if chan_id == 0 then
    error(string.format("Invalid arguments for task '%s'", task.name))
  elseif chan_id == -1 then
    error(string.format("Command '%s' not executable", vim.inspect(task.cmd)))
  else
    jobs.register(chan_id)
    self.chan_id = chan_id
  end
end

function ToggleTermStrategy:stop()
  if self.chan_id then
    vim.fn.jobstop(self.chan_id)
    self.chan_id = nil
  end
end

function ToggleTermStrategy:dispose()
  self:stop()
  util.soft_delete_buf(self.bufnr)
end

return ToggleTermStrategy
