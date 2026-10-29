-- Minuet's provider interface; compatible with the revision pinned in README.md.
return {
  is_available = function() return true end,
  complete = function(context, callback)
    require("open-compleat.completion").complete(context, callback)
  end,
}
