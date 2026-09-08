-- plugin/spark.lua -- the loader: one user command, nothing else. The key
-- is the user's one line (README); the plugin binds none itself, and the
-- module loads only when first used.
if vim.g.loaded_spark then return end
vim.g.loaded_spark = true

if vim.fn.has("nvim-0.9") ~= 1 then return end

vim.api.nvim_create_user_command("Spark", function(opts)
    require("spark").command(opts)
end, { nargs = "*", range = true, desc = "spark> without the prompt" })
