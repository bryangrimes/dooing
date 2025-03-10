-- Core CRUD + undo logic, removing duplicates, etc.

local vim = vim

local Todos = {}

function Todos.setup(M, config)
	-- Add a new todo
	function M.add_todo(text, priority_names)
		table.insert(M.todos, {
			text = text,
			done = false,
			in_progress = false,
			category = text:match("#(%w+)") or "",
			created_at = os.time(),
			priorities = priority_names,
			estimated_hours = nil,
			notes = "",
		})
		M.save_to_disk()
	end

	-- Toggle a todo's status
	function M.toggle_todo(index)
		local todo = M.todos[index]
		if not todo then
			return
		end

		-- pending -> in_progress -> done -> pending
		if not todo.in_progress and not todo.done then
			todo.in_progress = true
		elseif todo.in_progress then
			todo.in_progress = false
			todo.done = true
		else
			todo.done = false
		end
		M.save_to_disk()
	end

	-- Store a deleted todo in a small "undo" history
	local function store_deleted_todo(todo, index)
		table.insert(M.deleted_todos, 1, {
			todo = vim.deepcopy(todo),
			index = index,
			timestamp = os.time(),
		})
		if #M.deleted_todos > M.MAX_UNDO_HISTORY then
			table.remove(M.deleted_todos)
		end
	end

	-- Delete a todo
	function M.delete_todo(index)
		if M.todos[index] then
			local todo = M.todos[index]
			store_deleted_todo(todo, index)
			table.remove(M.todos, index)
			M.save_to_disk()
		end
	end

	-- Delete completed todos
	function M.delete_completed()
		local remaining = {}
		local removed_count = 0
		for i, todo in ipairs(M.todos) do
			if todo.done then
				store_deleted_todo(todo, i - removed_count)
				removed_count = removed_count + 1
			else
				table.insert(remaining, todo)
			end
		end
		M.todos = remaining
		M.save_to_disk()
	end

	-- Undo the most recently deleted todo
	function M.undo_delete()
		if #M.deleted_todos == 0 then
			vim.notify("No more todos to restore", vim.log.levels.INFO)
			return false
		end
		local last_deleted = table.remove(M.deleted_todos, 1)
		local insert_index = math.min(last_deleted.index, #M.todos + 1)
		table.insert(M.todos, insert_index, last_deleted.todo)
		M.save_to_disk()
		return true
	end

	-- Remove duplicates
	local function gen_hash(todo)
		local todo_string = vim.inspect(todo)
		return vim.fn.sha256(todo_string)
	end

	function M.remove_duplicates()
		local seen = {}
		local uniques = {}
		local removed = 0

		for _, todo in ipairs(M.todos) do
			if type(todo) == "table" then
				local hash = gen_hash(todo)
				if not seen[hash] then
					seen[hash] = true
					table.insert(uniques, todo)
				else
					removed = removed + 1
				end
			end
		end

		M.todos = uniques
		M.save_to_disk()
		return tostring(removed)
	end

	-- Confirmation-based deletion (used in UI)
	function M.delete_todo_with_confirmation(todo_index, win_id, calendar, callback)
		local current_todo = M.todos[todo_index]
		if not current_todo then
			return
		end

		if current_todo.done then
			-- If completed, no confirmation needed
			M.delete_todo(todo_index)
			if callback then
				callback()
			end
			return
		end

		-- Otherwise, build a small confirmation window
		local confirm_buf = vim.api.nvim_create_buf(false, true)
		local safe_text = current_todo.text:gsub("\n", " ")
		local line = "   ○ " .. safe_text

		local lang = calendar.get_language()
		lang = calendar.MONTH_NAMES[lang] and lang or "en"

		-- Add due date if present
		if current_todo.due_at then
			local date = os.date("*t", current_todo.due_at)
			local month = calendar.MONTH_NAMES[lang][date.month]
			local formatted_date = nil
			if lang == "pt" then
				formatted_date = string.format("%d de %s de %d", date.day, month, date.year)
			else
				formatted_date = string.format("%s %d, %d", month, date.day, date.year)
			end

			line = line .. " [@ " .. formatted_date .. "]"
			if current_todo.due_at < os.time() then
				line = line .. " [OVERDUE]"
			end
		end

		local lines = { "", "", line, "", "", "" }
		vim.api.nvim_buf_set_lines(confirm_buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(confirm_buf, "modifiable", false)
		vim.api.nvim_buf_set_option(confirm_buf, "buftype", "nofile")

		local ui = vim.api.nvim_list_uis()[1]
		local width = 120
		local height = #lines
		local row = math.floor((ui.height - height) / 2)
		local col = math.floor((ui.width - width) / 2)

		local delete_key = config.options.keymaps.delete_confirmation or "Y"
		local footer_text
		if delete_key:lower() == "y" then
			footer_text = " [" .. delete_key:upper() .. "]es - [N]o "
		else
			footer_text = delete_key .. "-Yes - [N]o "
		end

		local confirm_win = vim.api.nvim_open_win(confirm_buf, true, {
			relative = "editor",
			row = row,
			col = col,
			width = width,
			height = height,
			style = "minimal",
			border = "rounded",
			title = " Delete incomplete todo? ",
			title_pos = "center",
			footer = footer_text,
			footer_pos = "center",
			noautocmd = true,
		})

		vim.api.nvim_win_set_option(confirm_win, "cursorline", false)
		vim.api.nvim_win_set_option(confirm_win, "cursorcolumn", false)
		vim.api.nvim_win_set_option(confirm_win, "number", false)
		vim.api.nvim_win_set_option(confirm_win, "relativenumber", false)
		vim.api.nvim_win_set_option(confirm_win, "signcolumn", "no")
		vim.api.nvim_win_set_option(confirm_win, "mousemoveevent", false)

		-- Local helper for highlight
		local function get_priority_highlights(todo)
			if todo.done then
				return "DooingDone"
			elseif todo.in_progress then
				return "DooingInProgress"
			end

			if not config.options.priorities or #config.options.priorities == 0 then
				return "DooingPending"
			end

			if todo.priorities and #todo.priorities > 0 and config.options.priority_groups then
				local sorted_groups = {}
				for name, group in pairs(config.options.priority_groups) do
					table.insert(sorted_groups, { name = name, group = group })
				end
				table.sort(sorted_groups, function(a, b)
					return #a.group.members > #b.group.members
				end)

				for _, group_data in ipairs(sorted_groups) do
					local group = group_data.group
					local all_members_match = true
					for _, member in ipairs(group.members) do
						local found = false
						for _, prio in ipairs(todo.priorities) do
							if prio == member then
								found = true
								break
							end
						end
						if not found then
							all_members_match = false
							break
						end
					end
					if all_members_match then
						return group.hl_group or "DooingPending"
					end
				end
			end

			return "DooingPending"
		end

		local ns = vim.api.nvim_create_namespace("dooing_confirm")
		vim.api.nvim_buf_add_highlight(confirm_buf, ns, "WarningMsg", 0, 0, -1)
		vim.api.nvim_buf_add_highlight(confirm_buf, ns, get_priority_highlights(current_todo), 2, 0, #line)

		-- Tag highlight
		for tag in current_todo.text:gmatch("#(%w+)") do
			local start_idx = line:find("#" .. tag)
			if start_idx then
				vim.api.nvim_buf_add_highlight(confirm_buf, ns, "Type", 2, start_idx - 1, start_idx + #tag)
			end
		end

		-- Overdue highlight
		if current_todo.due_at then
			local due_date_start = line:find("%[@")
			local overdue_start = line:find("%[OVERDUE%]")
			if due_date_start then
				vim.api.nvim_buf_add_highlight(
					confirm_buf,
					ns,
					"Comment",
					2,
					due_date_start - 1,
					overdue_start and overdue_start - 1 or -1
				)
			end
			if overdue_start then
				vim.api.nvim_buf_add_highlight(confirm_buf, ns, "ErrorMsg", 2, overdue_start - 1, -1)
			end
		end

		-- Block movement
		local movement_keys = {
			"h",
			"j",
			"k",
			"l",
			"<Up>",
			"<Down>",
			"<Left>",
			"<Right>",
			"<C-f>",
			"<C-b>",
			"<C-u>",
			"<C-d>",
			"w",
			"b",
			"e",
			"ge",
			"0",
			"$",
			"^",
			"gg",
			"G",
		}
		for _, key in ipairs(movement_keys) do
			vim.keymap.set("n", key, function() end, { buffer = confirm_buf, nowait = true })
		end

		local function close_confirm()
			if vim.api.nvim_win_is_valid(confirm_win) then
				vim.api.nvim_win_close(confirm_win, true)
				vim.api.nvim_set_current_win(win_id)
			end
		end

		vim.keymap.set("n", delete_key, function()
			close_confirm()
			M.delete_todo(todo_index)
			if callback then
				callback()
			end
		end, { buffer = confirm_buf, nowait = true })

		vim.keymap.set("n", delete_key:upper(), function()
			close_confirm()
			M.delete_todo(todo_index)
			if callback then
				callback()
			end
		end, { buffer = confirm_buf, nowait = true })

		vim.keymap.set("n", "n", close_confirm, { buffer = confirm_buf, nowait = true })
		vim.keymap.set("n", "N", close_confirm, { buffer = confirm_buf, nowait = true })
		vim.keymap.set("n", "q", close_confirm, { buffer = confirm_buf, nowait = true })
		vim.keymap.set("n", "<Esc>", close_confirm, { buffer = confirm_buf, nowait = true })

		vim.api.nvim_create_autocmd("BufLeave", {
			buffer = confirm_buf,
			callback = close_confirm,
			once = true,
		})
	end
end

return Todos
