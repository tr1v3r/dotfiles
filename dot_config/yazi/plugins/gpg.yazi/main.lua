-- Sign, encrypt, decrypt, and verify files from Yazi.
--
-- Single selection:
--   file      -> <name>.gpg
--   directory -> <name>.tar.gz.gpg
--   sign file -> <name>.sig
--
-- Multiple selections from one directory:
--   items -> <chosen-name>.tar.gz.gpg
--
-- New archives carry a stable OpenPGP embedded filename so a regular file
-- ending in .tar.gz is not mistaken for an archive during decryption.

local ARCHIVE_MARKER = "yazi-gpg-archive-v1.tar.gz"
local DEFAULT_RECIPIENTS = {
	"899318F5A4423B72DF6A166FE4AF5FF89222F261",
	"C633910E8F351365DEAAF300046263C39890F916",
}
local DEFAULT_SIGNERS = {
	"C633910E8F351365DEAAF300046263C39890F916",
}

local function notify(content, level, timeout)
	ya.notify({
		title = "GPG",
		content = content,
		level = level or "info",
		timeout = timeout or 6,
	})
end

local function normalize_fingerprint(value)
	return tostring(value or ""):gsub("%s+", ""):upper()
end

local function normalize_fingerprints(values)
	if type(values) ~= "table" then
		values = { values }
	end

	local normalized, seen = {}, {}
	for _, value in ipairs(values) do
		local fingerprint = normalize_fingerprint(value)
		if not seen[fingerprint] then
			normalized[#normalized + 1] = fingerprint
			seen[fingerprint] = true
		end
	end
	return normalized
end

local get_config = ya.sync(function(state)
	return {
		recipients = state.recipients or state.recipient or DEFAULT_RECIPIENTS,
		signers = state.signers or state.signer or DEFAULT_SIGNERS,
	}
end)

local function url_is_regular(url)
	if url.spec then
		return url.spec.is_regular
	end
	return url.is_regular
end

local selected_or_hovered = ya.sync(function()
	local tab = cx.active
	local targets = {}

	for _, url in pairs(tab.selected) do
		targets[#targets + 1] = {
			path = tostring(url),
			parent = tostring(url.parent),
			name = tostring(url.name),
			is_local = url_is_regular(url),
		}
	end

	if #targets == 0 and tab.current.hovered then
		local hovered = tab.current.hovered
		targets[1] = {
			path = tostring(hovered.url),
			parent = tostring(hovered.url.parent),
			name = tostring(hovered.url.name),
			is_local = url_is_regular(hovered.url),
		}
	end

	return targets
end)

local function compact_error(value)
	local text = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if #text > 700 then
		text = text:sub(1, 697) .. "..."
	end
	return text ~= "" and text or "unknown error"
end

local function run(command, args)
	local output, err = Command(command):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):output()

	if not output then
		return false, "", compact_error(err)
	end

	return output.status.success, output.stdout or "", compact_error(output.stderr)
end

local function join(parent, name)
	return tostring(Url(parent):join(name))
end

local function inspect_path(path)
	local cha, err = fs.cha(Url(path), false)
	return cha, err
end

local function path_exists(path)
	local cha = inspect_path(path)
	return cha ~= nil
end

local function nonempty_file(path)
	local cha = inspect_path(path)
	return cha ~= nil and not cha.is_dir and cha.len > 0
end

local function remove_path(path, is_dir)
	if is_dir then
		return fs.remove("dir_all", Url(path))
	end
	return fs.remove("file", Url(path))
end

local function cleanup_dir(path)
	if path and path_exists(path) then
		fs.remove("dir_all", Url(path))
	end
end

local function make_temp_dir(parent)
	local url, err = fs.unique("dir", Url(join(parent, ".yazi-gpg-tmp")))
	if not url then
		return nil, compact_error(err)
	end

	local path = tostring(url)
	local ok, _, chmod_err = run("chmod", { "700", path })
	if not ok then
		cleanup_dir(path)
		return nil, "chmod failed: " .. chmod_err
	end

	return path
end

local function move_noreplace(source, target)
	if path_exists(target) then
		return false, "target already exists: " .. target
	end

	local ok, _, err = run("mv", { "-n", source, target })
	if not ok then
		return false, err
	end

	if path_exists(source) then
		return false, "target appeared while moving: " .. target
	end
	if not path_exists(target) then
		return false, "move completed without creating target: " .. target
	end

	return true
end

local function move_replace(source, target)
	local target_cha = inspect_path(target)
	if target_cha and target_cha.is_dir then
		return false, "replacement target is a directory: " .. target
	end

	local ok, err = fs.rename(Url(source), Url(target))
	if not ok then
		return false, compact_error(err)
	end
	if path_exists(source) then
		return false, "replacement completed but temporary file still exists: " .. source
	end
	if not path_exists(target) then
		return false, "replacement completed without creating target: " .. target
	end

	return true
end

local function valid_fingerprint(value)
	return value:match("^[0-9A-F]+$") ~= nil and #value == 40
end

local function validate_config(config)
	config.recipients = normalize_fingerprints(config.recipients)
	config.signers = normalize_fingerprints(config.signers)

	if #config.recipients == 0 then
		return false, "At least one recipient fingerprint is required"
	end
	for index, fingerprint in ipairs(config.recipients) do
		if not valid_fingerprint(fingerprint) then
			return false, string.format("Invalid recipient fingerprint at index %d", index)
		end
	end

	if #config.signers == 0 then
		return false, "At least one signer fingerprint is required"
	end
	for index, fingerprint in ipairs(config.signers) do
		if not valid_fingerprint(fingerprint) then
			return false, string.format("Invalid signer fingerprint at index %d", index)
		end
	end

	return true
end

local function has_public_key(fingerprint)
	local ok, stdout = run("gpg", {
		"--batch",
		"--with-colons",
		"--list-keys",
		fingerprint,
	})
	return ok and stdout:find("pub:", 1, true) ~= nil
end

local function has_secret_key(fingerprint)
	local ok, stdout = run("gpg", {
		"--batch",
		"--with-colons",
		"--list-secret-keys",
		fingerprint,
	})
	return ok and (stdout:find("sec:", 1, true) ~= nil or stdout:find("ssb:", 1, true) ~= nil)
end

local function validate_signing_key(config)
	for _, signer in ipairs(config.signers) do
		if not has_secret_key(signer) then
			return false, "Signing private key or smart-card stub is unavailable:\n" .. signer
		end
	end
	return true
end

local function validate_encrypt_keys(config)
	for _, recipient in ipairs(config.recipients) do
		if not has_public_key(recipient) then
			return false, "Encryption public key is unavailable:\n" .. recipient
		end
	end
	return validate_signing_key(config)
end

local function prepare_targets(raw_targets)
	if #raw_targets == 0 then
		return nil, "No file under cursor"
	end

	local targets, seen = {}, {}
	for _, item in ipairs(raw_targets) do
		if not item.is_local then
			return nil, "Remote and virtual URLs are not supported: " .. item.path
		end
		if not seen[item.path] then
			local cha, err = inspect_path(item.path)
			if not cha then
				return nil, string.format("Cannot inspect '%s': %s", item.name, compact_error(err))
			end
			if cha.is_block or cha.is_char or cha.is_fifo or cha.is_sock then
				return nil, "Unsupported special file: " .. item.path
			end

			item.is_dir = cha.is_dir
			item.is_link = cha.is_link
			targets[#targets + 1] = item
			seen[item.path] = true
		end
	end

	table.sort(targets, function(a, b)
		return a.path < b.path
	end)

	return targets
end

local function exact_confirmation(title)
	local answer, event = ya.input({
		title = title,
		pos = { "top-center", y = 3, w = 70 },
	})
	return event == 1 and answer:match("^%s*[yY]%s*$") ~= nil
end

local function valid_archive_name(value)
	return value ~= "" and value ~= "." and value ~= ".." and not value:find("/", 1, true) and not value:find("%z")
end

local function default_archive_output_name(parent)
	local parent_name = tostring(Url(parent).name or "selection")
	if parent_name == "" or parent_name == "/" then
		parent_name = "selection"
	end
	return parent_name .. ".tar.gz.gpg"
end

local function archive_output_name(parent)
	local default_name = default_archive_output_name(parent)
	local value, event = ya.input({
		title = "Encrypted bundle name (default: " .. default_name .. "):",
		pos = { "top-center", y = 3, w = 72 },
	})
	if event ~= 1 then
		return nil
	end

	value = value:match("^%s*(.-)%s*$")
	if value == "" then
		value = default_name
	elseif not value:lower():match("%.tar%.gz%.gpg$") then
		value = value .. ".tar.gz.gpg"
	end

	if not valid_archive_name(value) then
		return nil, "Invalid archive name"
	end
	return value
end

local function create_archive(output, parent, targets)
	local args = { "-czf", output, "-C", parent, "--" }
	for _, item in ipairs(targets) do
		args[#args + 1] = item.name
	end

	local ok, _, err = run("tar", args)
	if not ok then
		return false, "tar failed: " .. err
	end
	if not nonempty_file(output) then
		return false, "tar succeeded without creating a non-empty archive"
	end
	return true
end

local function append_key_options(args, option, fingerprints)
	for _, fingerprint in ipairs(fingerprints) do
		args[#args + 1] = option
		args[#args + 1] = fingerprint
	end
end

local function status_count(status, token)
	local expected = "[GNUPG:] " .. token
	local count = 0
	for line in status:gmatch("[^\r\n]+") do
		if line:sub(1, #expected) == expected then
			count = count + 1
		end
	end
	return count
end

local function sign_encrypt(input, output, embedded_name, config)
	local args = {
		"--batch",
		"--no-tty",
		"--no-auto-key-locate",
		"--trust-model",
		"always",
		"--status-fd",
		"1",
	}
	append_key_options(args, "--local-user", config.signers)
	append_key_options(args, "--recipient", config.recipients)
	for _, value in ipairs({
		"--set-filename",
		embedded_name,
		"--output",
		output,
		"--sign",
		"--encrypt",
		"--",
		input,
	}) do
		args[#args + 1] = value
	end

	local ok, status, err = run("gpg", args)

	if not ok then
		return false, "gpg failed: " .. err
	end
	if status_count(status, "SIG_CREATED") < #config.signers then
		return false, "gpg did not report every expected signature"
	end
	if not nonempty_file(output) then
		return false, "gpg succeeded without creating non-empty ciphertext"
	end
	return true
end

local function create_detached_signature(item, config, replace_existing)
	if item.is_dir then
		return false, "directory signing is not supported"
	end

	local final_output = item.path .. ".sig"
	if path_exists(final_output) and not replace_existing then
		return false, "target already exists: " .. final_output
	end

	local temp_dir, temp_err = make_temp_dir(item.parent)
	if not temp_dir then
		return false, "failed to create private temp directory: " .. compact_error(temp_err)
	end

	local temp_signature = join(temp_dir, item.name .. ".sig")
	local args = {
		"--batch",
		"--no-tty",
		"--status-fd",
		"1",
	}
	append_key_options(args, "--local-user", config.signers)
	for _, value in ipairs({
		"--output",
		temp_signature,
		"--detach-sign",
		"--",
		item.path,
	}) do
		args[#args + 1] = value
	end

	local ok, status, err = run("gpg", args)

	if not ok then
		cleanup_dir(temp_dir)
		return false, "gpg failed: " .. compact_error(err)
	end
	if status_count(status, "SIG_CREATED") < #config.signers then
		cleanup_dir(temp_dir)
		return false, "gpg did not report every expected signature"
	end
	if not nonempty_file(temp_signature) then
		cleanup_dir(temp_dir)
		return false, "gpg succeeded without creating a non-empty signature"
	end

	local moved, move_err
	if replace_existing then
		moved, move_err = move_replace(temp_signature, final_output)
	else
		moved, move_err = move_noreplace(temp_signature, final_output)
	end
	cleanup_dir(temp_dir)
	if not moved then
		return false, compact_error(move_err)
	end
	return true
end

local function sign(config)
	local targets, target_err = prepare_targets(selected_or_hovered())
	if not targets then
		notify(target_err, "error")
		return
	end

	local ok, key_err = validate_signing_key(config)
	if not ok then
		notify(key_err, "error", 8)
		return
	end

	local replacements = {}
	local replacement_count = 0
	local replacement_name
	for _, item in ipairs(targets) do
		if not item.is_dir then
			local output = item.path .. ".sig"
			local output_cha = inspect_path(output)
			if output_cha and not output_cha.is_dir then
				replacements[output] = true
				replacement_count = replacement_count + 1
				replacement_name = item.name .. ".sig"
			end
		end
	end

	if replacement_count > 0 then
		local title = replacement_count == 1
				and string.format("Signature exists. Type y to replace '%s':", replacement_name)
			or string.format("%d signatures already exist. Type y to replace them:", replacement_count)
		if not exact_confirmation(title) then
			return
		end
	end

	local succeeded, failures = 0, {}
	for _, item in ipairs(targets) do
		local signed, sign_err = create_detached_signature(item, config, replacements[item.path .. ".sig"] == true)
		if signed then
			succeeded = succeeded + 1
		else
			failures[#failures + 1] = item.name .. ": " .. compact_error(sign_err)
		end
	end
	ya.emit("escape", { select = true })

	local summary = string.format("Detached signatures: %d created, %d failed", succeeded, #failures)
	if #failures > 0 then
		summary = summary .. "\n" .. table.concat(failures, "\n")
	end
	local level = #failures == 0 and "info" or (succeeded > 0 and "warn" or "error")
	notify(compact_error(summary), level, 10)
end

local function finish_source_removal(targets)
	local failed = {}
	for _, item in ipairs(targets) do
		local ok, err = remove_path(item.path, item.is_dir and not item.is_link)
		if not ok then
			failed[#failed + 1] = string.format("%s (%s)", item.name, compact_error(err))
		end
	end
	return failed
end

local function build_encryption_plan(targets, allow_existing)
	local parent, output_name, archive_mode
	if #targets > 1 then
		parent = targets[1].parent
		for _, item in ipairs(targets) do
			if item.parent ~= parent then
				return nil, "Multiple selections must have the same parent directory"
			end
		end

		if allow_existing then
			output_name = default_archive_output_name(parent)
		else
			local target_err
			output_name, target_err = archive_output_name(parent)
			if not output_name then
				return nil, target_err, target_err == nil
			end
		end
		archive_mode = true
	else
		local item = targets[1]
		parent = item.parent
		archive_mode = item.is_dir and not item.is_link
		output_name = archive_mode and (item.name .. ".tar.gz.gpg") or (item.name .. ".gpg")
	end

	local final_output = join(parent, output_name)
	local output_cha = inspect_path(final_output)
	if output_cha and not allow_existing then
		return nil, "Target already exists: " .. final_output
	end
	if output_cha and output_cha.is_dir then
		return nil, "Target is a directory and cannot be replaced: " .. final_output
	end
	for _, item in ipairs(targets) do
		if item.path == final_output then
			return nil, "Encrypted output conflicts with a selected source"
		end
	end

	return {
		targets = targets,
		parent = parent,
		output_name = output_name,
		final_output = final_output,
		archive_mode = archive_mode,
		replace_existing = output_cha ~= nil,
	}
end

local function perform_encryption(plan, config, keep_sources)
	local temp_dir, temp_err = make_temp_dir(plan.parent)
	if not temp_dir then
		return false, "Failed to create private temp directory: " .. temp_err
	end

	local success, operation_err = pcall(function()
		local input = plan.targets[1].path
		if plan.archive_mode then
			input = join(temp_dir, ARCHIVE_MARKER)
			local archived, archive_err = create_archive(input, plan.parent, plan.targets)
			if not archived then
				error(archive_err)
			end
		end

		local temp_cipher = join(temp_dir, plan.output_name)
		local encrypted, encrypt_err =
			sign_encrypt(input, temp_cipher, plan.archive_mode and ARCHIVE_MARKER or plan.targets[1].name, config)
		if not encrypted then
			error(encrypt_err)
		end

		local moved, move_err
		if plan.replace_existing then
			moved, move_err = move_replace(temp_cipher, plan.final_output)
		else
			moved, move_err = move_noreplace(temp_cipher, plan.final_output)
		end
		if not moved then
			error(move_err)
		end
	end)

	cleanup_dir(temp_dir)
	if not success then
		return false, compact_error(operation_err)
	end

	local removal_failures = {}
	if not keep_sources then
		removal_failures = finish_source_removal(plan.targets)
	end
	return true, nil, removal_failures
end

local function encrypt_each(config, targets, keep_sources)
	local jobs, failures = {}, {}
	local replacement_count = 0
	for _, item in ipairs(targets) do
		local plan, plan_err = build_encryption_plan({ item }, keep_sources)
		if not plan then
			failures[#failures + 1] = item.name .. ": " .. compact_error(plan_err)
		else
			jobs[#jobs + 1] = { item = item, plan = plan }
			if plan.replace_existing then
				replacement_count = replacement_count + 1
			end
		end
	end

	if keep_sources then
		if replacement_count > 0 then
			local title = replacement_count == 1 and "Ciphertext already exists. Type y to replace it:"
				or string.format("%d ciphertext files already exist. Type y to replace them:", replacement_count)
			if not exact_confirmation(title) then
				return
			end
		end
	elseif
		not exact_confirmation(
			string.format("Type y to sign & encrypt %d item(s) separately (replace originals):", #targets)
		)
	then
		return
	end

	local succeeded, removal_failures = 0, {}
	for _, job in ipairs(jobs) do
		local encrypted, encrypt_err, remove_errs = perform_encryption(job.plan, config, keep_sources)
		if not encrypted then
			failures[#failures + 1] = job.item.name .. ": " .. compact_error(encrypt_err)
		else
			succeeded = succeeded + 1
			for _, remove_err in ipairs(remove_errs) do
				removal_failures[#removal_failures + 1] = remove_err
			end
		end
	end
	ya.emit("escape", { select = true })

	local summary = string.format("Encrypted separately: %d succeeded, %d failed", succeeded, #failures)
	if #failures > 0 then
		summary = summary .. "\n" .. table.concat(failures, "\n")
	end
	if #removal_failures > 0 then
		summary = summary
			.. string.format("\n%d original(s) were kept:\n", #removal_failures)
			.. table.concat(removal_failures, "\n")
	end

	local level = #failures > 0 and (succeeded > 0 and "warn" or "error")
		or (#removal_failures > 0 and "warn" or "info")
	notify(compact_error(summary), level, 10)
end

local function encrypt(config, options)
	local targets, target_err = prepare_targets(selected_or_hovered())
	if not targets then
		notify(target_err, "error")
		return
	end

	local ok, key_err = validate_encrypt_keys(config)
	if not ok then
		notify(key_err, "error", 8)
		return
	end

	options = options or {}
	if options.each then
		encrypt_each(config, targets, options.keep)
		return
	end

	local plan, plan_err, cancelled = build_encryption_plan(targets, options.keep)
	if not plan then
		if not cancelled then
			notify(plan_err, "warn")
		end
		return
	end

	if options.keep then
		if
			plan.replace_existing
			and not exact_confirmation("Ciphertext exists. Type y to replace '" .. plan.output_name .. "':")
		then
			return
		end
	else
		local confirmation = #targets > 1
				and string.format("Type y to sign, encrypt & replace %d items as '%s':", #targets, plan.output_name)
			or string.format("Type y to sign, encrypt & replace '%s':", targets[1].name)
		if not exact_confirmation(confirmation) then
			return
		end
	end

	local encrypted, encrypt_err, removal_failures = perform_encryption(plan, config, options.keep)
	if not encrypted then
		notify("Encryption stopped; originals were kept.\n" .. compact_error(encrypt_err), "error", 9)
		return
	end
	ya.emit("escape", { select = true })

	if #removal_failures > 0 then
		notify(
			string.format(
				"Ciphertext created, but %d original(s) could not be removed:\n%s",
				#removal_failures,
				table.concat(removal_failures, "\n")
			),
			"warn",
			10
		)
	else
		local suffix = options.keep and " (originals kept)" or ""
		notify(string.format("Signed and encrypted %d item(s) -> %s%s", #targets, plan.final_output, suffix), "info", 8)
	end
end

local function status_has(status, token)
	return status:find("[GNUPG:] " .. token, 1, true) ~= nil
end

local function status_has_signature(status)
	for _, token in ipairs({
		"GOODSIG",
		"VALIDSIG",
		"BADSIG",
		"ERRSIG",
		"EXPSIG",
		"EXPKEYSIG",
		"REVKEYSIG",
	}) do
		if status_has(status, token) then
			return true
		end
	end
	return false
end

local function missing_valid_signers(status, expected_signers)
	local valid = {}
	for line in status:gmatch("[^\r\n]+") do
		if line:find("[GNUPG:] VALIDSIG ", 1, true) == 1 then
			for token in line:gmatch("%S+") do
				local fingerprint = normalize_fingerprint(token)
				if valid_fingerprint(fingerprint) then
					valid[fingerprint] = true
				end
			end
		end
	end

	local missing = {}
	for _, signer in ipairs(expected_signers) do
		if not valid[signer] then
			missing[#missing + 1] = signer
		end
	end
	return missing
end

local function signature_failure(status, config)
	local missing = missing_valid_signers(status, config.signers)
	if #missing > 0 then
		return "missing or invalid signer(s): " .. table.concat(missing, ", ")
	end
	return "one or more signatures are invalid"
end

local function embedded_filename(status)
	for line in status:gmatch("[^\r\n]+") do
		local value = line:match("^%[GNUPG:%] PLAINTEXT %S+ %S+ (.+)$")
		if value then
			return value
		end
	end
	return nil
end

local function decrypt_once(input, output, config, assert_signers)
	local args = {
		"--batch",
		"--no-tty",
		"--no-auto-key-retrieve",
		"--proc-all-sigs",
		"--status-fd",
		"1",
	}
	if assert_signers then
		append_key_options(args, "--assert-signer", config.signers)
	end
	args[#args + 1] = "--output"
	args[#args + 1] = output
	args[#args + 1] = "--decrypt"
	args[#args + 1] = "--"
	args[#args + 1] = input

	return run("gpg", args)
end

local function verify_encrypted_once(input, config)
	local args = {
		"--batch",
		"--no-tty",
		"--no-auto-key-retrieve",
		"--proc-all-sigs",
		"--status-fd",
		"2",
	}
	append_key_options(args, "--assert-signer", config.signers)
	for _, value in ipairs({ "--decrypt", "--", input }) do
		args[#args + 1] = value
	end

	local child, spawn_err = Command("gpg"):arg(args):stdout(Command.NULL):stderr(Command.PIPED):spawn()
	if not child then
		return false, "", compact_error(spawn_err)
	end

	local output, wait_err = child:wait_with_output()
	if not output then
		return false, "", compact_error(wait_err)
	end
	return output.status.success, output.stderr or "", compact_error(output.stderr)
end

local function verify_detached_once(signature, source, config)
	local args = {
		"--batch",
		"--no-tty",
		"--no-auto-key-retrieve",
		"--proc-all-sigs",
		"--status-fd",
		"1",
	}
	append_key_options(args, "--assert-signer", config.signers)
	for _, value in ipairs({
		"--verify",
		"--",
		signature,
		source,
	}) do
		args[#args + 1] = value
	end
	return run("gpg", args)
end

local function verify(config)
	local targets, target_err = prepare_targets(selected_or_hovered())
	if not targets then
		notify(target_err, "error")
		return
	end

	local verified, failures = 0, {}
	for _, item in ipairs(targets) do
		if item.is_dir then
			failures[#failures + 1] = item.name .. ": directories cannot be verified directly"
		elseif item.path:lower():match("%.gpg$") then
			local ok, status, err = verify_encrypted_once(item.path, config)
			local missing = missing_valid_signers(status, config.signers)
			if ok and status_has(status, "DECRYPTION_OKAY") and #missing == 0 then
				verified = verified + 1
			elseif status_has(status, "DECRYPTION_OKAY") and not status_has_signature(status) then
				failures[#failures + 1] = item.name .. ": unsigned"
			elseif status_has(status, "DECRYPTION_OKAY") then
				failures[#failures + 1] = item.name .. ": " .. signature_failure(status, config)
			else
				failures[#failures + 1] = item.name .. ": decryption failed (" .. compact_error(err) .. ")"
			end
		elseif item.path:lower():match("%.sig$") then
			local source = item.path:sub(1, -5)
			local source_cha = inspect_path(source)
			if not source_cha then
				failures[#failures + 1] = item.name .. ": source file is missing: " .. source
			elseif source_cha.is_dir then
				failures[#failures + 1] = item.name .. ": inferred source is a directory"
			else
				local ok, status, err = verify_detached_once(item.path, source, config)
				local missing = missing_valid_signers(status, config.signers)
				if ok and #missing == 0 then
					verified = verified + 1
				elseif status_has_signature(status) then
					failures[#failures + 1] = item.name .. ": " .. signature_failure(status, config)
				else
					failures[#failures + 1] = item.name .. ": verification failed (" .. compact_error(err) .. ")"
				end
			end
		else
			failures[#failures + 1] = item.name .. ": not a .gpg or .sig file"
		end
	end

	local summary = string.format(
		"Signature verification: %d valid, %d failed\nExpected signers: %s",
		verified,
		#failures,
		table.concat(config.signers, ", ")
	)
	if #failures > 0 then
		summary = summary .. "\n" .. table.concat(failures, "\n")
	end
	local level = #failures == 0 and "info" or (verified > 0 and "warn" or "error")
	notify(compact_error(summary), level, 10)
end

local function decrypt_payload(input, output, config)
	local ok, status, err = decrypt_once(input, output, config, true)
	local missing = missing_valid_signers(status, config.signers)
	if ok and status_has(status, "DECRYPTION_OKAY") and #missing == 0 and path_exists(output) then
		return true, status, false
	end

	local unsigned_legacy = status_has(status, "DECRYPTION_OKAY") and not status_has_signature(status)
	if not unsigned_legacy then
		if path_exists(output) then
			fs.remove("file", Url(output))
		end
		local message = status_has(status, "DECRYPTION_OKAY")
				and ("Signature verification failed: " .. signature_failure(status, config))
			or ("Decryption failed: " .. err)
		return false, nil, false, message
	end

	if path_exists(output) then
		fs.remove("file", Url(output))
	end
	local answer, event = ya.input({
		title = "Unsigned legacy GPG file. Type legacy to decrypt:",
		pos = { "top-center", y = 3, w = 68 },
	})
	if event ~= 1 or answer:match("^%s*(.-)%s*$"):lower() ~= "legacy" then
		return false, nil, true, "Legacy decryption cancelled"
	end

	ok, status, err = decrypt_once(input, output, config, false)
	if not ok or not status_has(status, "DECRYPTION_OKAY") or not path_exists(output) then
		if path_exists(output) then
			fs.remove("file", Url(output))
		end
		return false, nil, true, "Legacy decryption failed: " .. err
	end
	return true, status, true
end

local function safe_archive_entries(archive)
	local ok, stdout, err = run("tar", { "-tzf", archive })
	if not ok then
		return nil, "Cannot list archive: " .. err
	end

	local roots, count = {}, 0
	for line in stdout:gmatch("[^\r\n]+") do
		local name = line:gsub("^%./", "")
		if
			name == ""
			or name == "."
			or name:sub(1, 1) == "/"
			or name == ".."
			or name:match("^%.%./")
			or name:match("/%.%./")
			or name:match("/%.%.$")
		then
			return nil, "Unsafe archive path: " .. line
		end

		local root = name:match("^([^/]+)")
		if root and not roots[root] then
			roots[root] = true
			count = count + 1
		end
	end

	if count == 0 then
		return nil, "Archive is empty"
	end
	return roots
end

local function restore_archive(payload, encrypted_path, parent)
	local roots, list_err = safe_archive_entries(payload)
	if not roots then
		return false, list_err
	end
	for root in pairs(roots) do
		if path_exists(join(parent, root)) then
			return false, "Restore target already exists: " .. join(parent, root)
		end
	end

	local extract_dir, err = fs.unique("dir", Url(join(parent, ".yazi-gpg-restore")))
	if not extract_dir then
		return false, "Cannot create restore directory: " .. compact_error(err)
	end
	extract_dir = tostring(extract_dir)
	local chmod_ok, _, chmod_err = run("chmod", { "700", extract_dir })
	if not chmod_ok then
		cleanup_dir(extract_dir)
		return false, "Cannot protect restore directory: " .. chmod_err
	end

	local ok, _, extract_err = run("tar", { "-xzf", payload, "-C", extract_dir })
	if not ok then
		cleanup_dir(extract_dir)
		return false, "tar extraction failed: " .. extract_err
	end

	local files, read_err = fs.read_dir(Url(extract_dir), { resolve = false })
	if not files or #files == 0 then
		cleanup_dir(extract_dir)
		return false, "Extracted archive has no top-level items: " .. compact_error(read_err)
	end

	for _, file in ipairs(files) do
		local target = join(parent, file.name)
		local moved, move_err = move_noreplace(tostring(file.url), target)
		if not moved then
			cleanup_dir(extract_dir)
			return false, "Failed to restore '" .. file.name .. "': " .. move_err
		end
	end
	cleanup_dir(extract_dir)

	local removed, remove_err = fs.remove("file", Url(encrypted_path))
	if not removed then
		return true, "Restored successfully, but ciphertext was kept: " .. compact_error(remove_err)
	end
	return true
end

local function restore_file(payload, encrypted_path)
	if not encrypted_path:lower():match("%.gpg$") then
		return false, "Encrypted file must end in .gpg"
	end
	local output = encrypted_path:sub(1, -5)
	if path_exists(output) then
		return false, "Restore target already exists: " .. output
	end

	local moved, move_err = move_noreplace(payload, output)
	if not moved then
		return false, move_err
	end

	local removed, remove_err = fs.remove("file", Url(encrypted_path))
	if not removed then
		return true, "Restored successfully, but ciphertext was kept: " .. compact_error(remove_err)
	end
	return true
end

local function decrypt_item(item, config)
	local temp_dir, temp_err = make_temp_dir(item.parent)
	if not temp_dir then
		return false, "Failed to create private temp directory: " .. compact_error(temp_err)
	end
	local payload = join(temp_dir, "payload")

	local decrypted, status, legacy, decrypt_err = decrypt_payload(item.path, payload, config)
	if not decrypted then
		cleanup_dir(temp_dir)
		return false, compact_error(decrypt_err)
	end

	local marker = embedded_filename(status)
	local archive_mode = marker == ARCHIVE_MARKER or (legacy and item.path:lower():match("%.tar%.gz%.gpg$"))
	local restored, restore_err
	if archive_mode then
		restored, restore_err = restore_archive(payload, item.path, item.parent)
	else
		restored, restore_err = restore_file(payload, item.path)
	end

	cleanup_dir(temp_dir)

	if not restored then
		return false, "ciphertext kept: " .. compact_error(restore_err)
	end
	if restore_err then
		return true, compact_error(restore_err)
	end
	if legacy then
		return true, "decrypted unsigned legacy file"
	end
	return true
end

local function decrypt(config)
	local targets, target_err = prepare_targets(selected_or_hovered())
	if not targets then
		notify(target_err, "error")
		return
	end

	local candidates, failures = {}, {}
	for _, item in ipairs(targets) do
		if item.is_dir or not item.path:lower():match("%.gpg$") then
			failures[#failures + 1] = item.name .. ": not a .gpg file"
		else
			candidates[#candidates + 1] = item
		end
	end

	if #candidates == 0 then
		notify("No .gpg files selected\n" .. table.concat(failures, "\n"), "warn", 9)
		return
	end

	local confirmation = #candidates == 1 and "Type y to decrypt, verify & replace '" .. candidates[1].name .. "':"
		or string.format("Type y to decrypt, verify & replace %d files:", #candidates)
	if not exact_confirmation(confirmation) then
		return
	end

	local succeeded, warnings = 0, {}
	for _, item in ipairs(candidates) do
		local restored, detail = decrypt_item(item, config)
		if restored then
			succeeded = succeeded + 1
			if detail then
				warnings[#warnings + 1] = item.name .. ": " .. compact_error(detail)
			end
		else
			failures[#failures + 1] = item.name .. ": " .. compact_error(detail)
		end
	end
	ya.emit("escape", { select = true })

	local summary = string.format("Decryption: %d succeeded, %d failed", succeeded, #failures)
	if #failures > 0 then
		summary = summary .. "\n" .. table.concat(failures, "\n")
	end
	if #warnings > 0 then
		summary = summary .. "\nWarnings:\n" .. table.concat(warnings, "\n")
	end
	local level = #failures > 0 and (succeeded > 0 and "warn" or "error") or (#warnings > 0 and "warn" or "info")
	notify(compact_error(summary), level, 10)
end

local function entry(_, job)
	local config = get_config()
	local config_ok, config_err = validate_config(config)
	if not config_ok then
		notify(config_err, "error")
		return
	end

	local args = job.args or {}
	local action = args[1] or ""
	local ok, err
	if action == "encrypt" then
		ok, err = pcall(encrypt, config, {
			each = args.each == true,
			keep = args.keep == true,
		})
	elseif action == "sign" then
		ok, err = pcall(sign, config)
	elseif action == "decrypt" then
		ok, err = pcall(decrypt, config)
	elseif action == "verify" then
		ok, err = pcall(verify, config)
	else
		notify("Unknown action: " .. tostring(action), "error")
		return
	end

	if not ok then
		notify("Unexpected plugin error: " .. compact_error(err), "error", 10)
	end
end

local function setup(state, options)
	options = options or {}
	state.recipients = normalize_fingerprints(options.recipients or options.recipient or DEFAULT_RECIPIENTS)
	state.signers = normalize_fingerprints(options.signers or options.signer or DEFAULT_SIGNERS)
end

return {
	entry = entry,
	setup = setup,
}
