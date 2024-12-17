--mod-version:3

-- A Lua based reWrapText/justify plugin for the micro editor

local core    = require "core"
local command = require "core.command"
local common  = require "core.common"
local config  = require "core.config"
local keymap  = require "core.keymap"

-- config

config.plugins.ReWrapText = common.merge({
  textWidth          = 75,
  commentLineMarkers = "// # -- ; >",
  config_spec = {
    name = "ReWrap Text",
    {
      label = "Text Width",
      description = "Controls the length of a line of text",
      path = "textWidth",
      type = "number",
      default = "75",
      min = 50,
      max = 150
    },
    {
      label = "Comment Line Markers",
      description = "A space delimited list of comment line markers",
      path = "commentLineMarkers",
      type = "string",
      default = "// # -- ; >"
    }
  }
}, config.plugins.ReWrapText)

local ReWrapText = {}

-- local tmpName = os.time()
-- local logFile = io.open("/tmp/reWrapTextLog-"..tmpName, 'w')
-- 
-- local function logMsg(msg)
--   if logFile then
--     if msg == nil then
--       -- Protect a micro.Log from appending nil values to strings...
--       msg = "(nil)"
--     end
--     logFile:write(msg.."\n")
--     logFile:flush()
--   end
-- end
-- 
-- logMsg("Hello world from reWrapText")
-- logMsg(config.plugins.ReWrapText.textWidth)
-- logMsg(config.plugins.ReWrapText.commentLineMarkers)
-- logMsg(nil)

-- Append a value (string) to a table for later concatenating
--
local function appendValue(aTable, aValue)
  aTable[#aTable+1] = aValue
end

----------------------------------------------------------------------------------
-- document selection helpers...
--

local function getDoc()
  local doc = core.active_view.doc
  if not doc.rewraptext then
    doc.rewraptext = {}
  end
  return doc
end

local function getSelection(doc)
  return doc:get_selection(true)
end

local function hasSelection(doc)
  local firstLine, firstChar, lastLine, lastChar = getSelection(doc)
  return (firstLine ~= lastLine) or (firstChar ~= lastChar)
end

local function moveCursorDownOneLine(doc)
    local firstLine, firstChar, _, _ = getSelection(doc)
    local nextLine = firstLine+1
    doc:set_selection(nextLine, firstChar, nextLine, firstChar, false)
end

----------------------------------------------------------------------------------
-- structured commented block finders

-- Find a comment marker from the global "reWrapText.commentLineMarkers" 
-- option 
--
local function findCommentMarker(possibleCommentMarker)
  if possibleCommentMarker == nil then return nil end
  --
  local commentMarkers = config.plugins.ReWrapText.commentLineMarkers
  for aStr in commentMarkers:gmatch("(%S+)") do
    local _, endCommentIndex =
      possibleCommentMarker:find(aStr,1,true)
    if endCommentIndex ~= nil and
       endCommentIndex == possibleCommentMarker:len() then
      return possibleCommentMarker
    end
  end
  return nil
end

local function getCommentMarkerFromLine(aLine)
  return aLine:match("()(%S+)()")
end

-- Find the block structure for a pre-selected block
--
local function findBlockStructure(doc, firstLine, lastLine)
  local indentEnd = 1000
  local blockCommentMarkers = {}
  local indentedCommentEnd = 1000
  --
  local curLine = firstLine
  while curLine <= lastLine do
    local curLineStr = doc.lines[curLine]
    local startIndex, commentMarker, endIndex =
      getCommentMarkerFromLine(curLineStr)
    if startIndex ~= nil and startIndex < indentEnd then
      indentEnd = startIndex
    end
    if endIndex ~= nil and endIndex < indentedCommentEnd then
      indentedCommentEnd = endIndex
    end
    commentMarker = findCommentMarker(commentMarker)
    if commentMarker ~= nil then
      blockCommentMarkers[commentMarker] = true
    else
      indentedCommentEnd = indentEnd
    end
    curLine = curLine + 1
  end
  local blockCommentMarker = "unknown"
  for key, _ in pairs(blockCommentMarkers) do
    if blockCommentMarker == "unknown" then
      blockCommentMarker = key
    elseif blockCommentMarker ~= key then
      ---@diagnostic disable-next-line:cast-local-type
      blockCommentMarker = nil
      indentedCommentEnd = indentEnd
    end
  end
  if blockCommentMarker == "unknown" then
    ---@diagnostic disable-next-line:cast-local-type
    blockCommentMarker = nil
  end
  return indentEnd - 1,
    blockCommentMarker,
    indentedCommentEnd
end

-- Find the block structure given just a cursor position
--
local function findUnselectedCommentedBlock(doc)
  --
  -- Start by determining the indentation and possible comment symbol
  -- of the line on which the cursor is located.
  --
  local firstLine, _, lastLine, _ = getSelection(doc)
  local curLineStr = doc.lines[firstLine]
  local startIndex, commentMarker, endIndex =
    getCommentMarkerFromLine(curLineStr)
  if startIndex    == nil or
    commentMarker == nil or
    endIndex == nil then
    -- we are on a blank line....
    return nil, nil, nil, nil, nil
  end
  --
  local indentEnd          = startIndex
  local indentedCommentEnd = endIndex
  local blockCommentMarker = findCommentMarker(commentMarker)
  if blockCommentMarker == nil then
    indentedCommentEnd = indentEnd
  end
  --
  -- Now move up to find the first line which has a different 
  -- indentation or comment marker
  --
  firstLine = firstLine - 1
  while 0 < firstLine do
    curLineStr = doc.lines[firstLine]
    startIndex, commentMarker, endIndex =
     getCommentMarkerFromLine(curLineStr)
    if blockCommentMarker == nil then
      if startIndex == nil or
        startIndex ~= indentEnd then
        -- we have found a blank line or a line with different indentation
        -- move back one line and break
        firstLine = firstLine + 1
        break
      end
    else
      if startIndex == nil or
        startIndex ~= indentEnd or
        commentMarker ~= blockCommentMarker or
        endIndex == nil or
        endIndex ~= indentedCommentEnd then
        -- we have found a blank line, a line with different indentation
        -- OR a line with a different comment marker
        -- move back one line and break
        firstLine = firstLine + 1
        break
      end
    end
    firstLine = firstLine - 1
  end
  --
  -- Now move down to find the last line which has a different
  -- indentation or comment marker
  --
  lastLine = lastLine + 1
  while lastLine < #doc.lines do
    curLineStr = doc.lines[lastLine]
    startIndex, commentMarker, endIndex =
      getCommentMarkerFromLine(curLineStr)
    if blockCommentMarker == nil then
      if startIndex == nil or
        startIndex ~= indentEnd then
        -- we have found a blank line or a line with different indentation
        -- move back one line and break
        lastLine = lastLine - 1
        break
      end
    else
      if startIndex == nil or
        startIndex ~= indentEnd or
        commentMarker ~= blockCommentMarker or
        endIndex == nil or
        endIndex ~= indentedCommentEnd then
        -- we have found a blank line, a line with different indentation
        -- OR a line with a different comment marker
        -- move back one line and break
        lastLine = lastLine - 1
        break
      end
    end
    lastLine = lastLine + 1
  end
  --
  return firstLine,
   lastLine,
   indentEnd - 1,
   blockCommentMarker,
   indentedCommentEnd
end

-- Determine block structure for either a pre-selected block or a block 
-- with just cursor. This function is used by both the 
-- reWrapText.commentBlock and reWrapText.reWrapText. 
--
local function determineBlockStructure(doc)

  local indentEnd, blockCommentMarker, indentedCommentEnd
  local firstLine, _, lastLine, lastChar = getSelection(doc)
  if hasSelection(doc) then
    if lastChar == 1 and firstLine < lastLine then
      lastLine = lastLine -1
     end
    indentEnd, blockCommentMarker, indentedCommentEnd =
      findBlockStructure(doc, firstLine, lastLine)
  else
    firstLine, lastLine, indentEnd, blockCommentMarker, indentedCommentEnd =
      findUnselectedCommentedBlock(doc)
  end
  if firstLine ~= nil and firstLine < 1 then firstLine = 1 end
  if lastLine ~= nil and lastLine < 1 then lastLine = 1 end
  if lastLine ~= nil and #doc.lines <= lastLine then
    lastLine = #doc.lines - 1
   end
  return firstLine,
    lastLine,
    indentEnd,
    blockCommentMarker,
    indentedCommentEnd
end

-- Determine the block comment marker using any possibly previously saved 
-- "lastBlockCommentMarkers", or the buffer's "commenttype" settings.
--
local function determineBlockCommentMarker(doc, blockCommentMarker)
  if not blockCommentMarker then
    -- we have not determined a unique blockCommentMarker
    -- do we have a previous comment marker?
    -- if so ... we should use it
    blockCommentMarker = doc.rewraptext.lastBlockCommentMarker
    if not blockCommentMarker then
      -- we have no previous block comment marker so use commentype
      blockCommentMarker = doc.syntax.comment
      if blockCommentMarker then
        blockCommentMarker = blockCommentMarker:match("(%S+)")
      end
      if not blockCommentMarker then
        blockCommentMarker = "#"
      end
    end
  end
  -- store the current comment marker for possible later use
  doc.rewraptext.lastBlockCommentMarker = blockCommentMarker
  return blockCommentMarker
end

----------------------------------------------------------------------------------
-- The reWrapText.selectCommentBlock method
--
local function selectCommentedBlock()
  local doc = getDoc()
  --
  -- If the user has made a selection... just make it a full block...
  --
  if hasSelection(doc) then
    local firstLine, _, lastLine, _ = getSelection(doc)
    local lastChar  = #doc.lines[lastLine]
    doc:set_selection(firstLine, 1, lastLine, lastChar, false)
    return
  end
  --
  local firstLine, lastLine, _, _, _ = findUnselectedCommentedBlock(doc)
  if firstLine == nil or lastLine == nil then return end
  local lastChar  = #doc.lines[lastLine]
  doc:set_selection(firstLine, 1, lastLine, lastChar, false)
end

----------------------------------------------------------------------------------
-- The reWrapText.commentBlock function
--
local function commentBlock()
  local doc = getDoc()
  local firstLine, lastLine, indentEnd, blockCommentMarker, indentedCommentEnd =
    determineBlockStructure(doc)
  --
  if firstLine == nil or lastLine == nil then
    return moveCursorDownOneLine(doc)
  end
  --
  -- determine what the comment marker should be...
  --
  blockCommentMarker = determineBlockCommentMarker(doc, blockCommentMarker)
  --
  local commentMarker = ""
  if indentEnd + 1 == indentedCommentEnd then
    -- we have an uncommented block... so add the comment marker
    commentMarker = blockCommentMarker.." "
  else
    -- we have a commented block... so remove the comment marker
    commentMarker = ""
    indentedCommentEnd = indentedCommentEnd + 1
  end
  --
  -- ensure we have a full block selected
  --
  doc:set_selection(firstLine, 1, lastLine, #doc.lines[lastLine])
  --
  -- now comment/uncomment the block
  --
  local newLines = {}
  local curLine = firstLine
  while curLine <= lastLine do
    local curLineStr = doc.lines[curLine]
    local indentStr  = curLineStr:sub(1, indentEnd)
    local restOfStr  = curLineStr:sub(indentedCommentEnd)
    appendValue(newLines, indentStr .. commentMarker .. restOfStr)
    curLine = curLine + 1
  end
  local newLinesStr = table.concat(newLines)
  newLinesStr = newLinesStr:sub(1,-2)
  doc:remove(firstLine, 1, lastLine, #doc.lines[lastLine])
  doc:text_input(newLinesStr)
  moveCursorDownOneLine(doc)
end

----------------------------------------------------------------------------------
-- The reWrapText.reWrapText helper functions
--

-- ReWrap the text provided as a collection of words
-- returns a table of the re-wrapped lines of text
--
local function reWrapWords(someLines, textWidth, indentStr)
  --
  -- Split a collection of strings into component "words"
  -- by splitting on white space
  -- inspired by http://lua-users.org/wiki/SplitJoin
  -- Example: splitOnWhiteSpace("this is\ta\ntest ")
  --
  local someWords = {}
  for _, aString in ipairs(someLines) do
    aString:gsub("(%S+)", function(c) appendValue(someWords, c) end)
  end
  --
  -- now re-wrap the text
  --
  local newText = {}
  local indentLen = indentStr:len()
  appendValue(newText, indentStr)
  local lineLength = indentLen
  for i, aWord in ipairs(someWords) do
    if textWidth < (lineLength + aWord:len() + 1) then
      appendValue(newText, "\n")
      appendValue(newText, indentStr)
      appendValue(newText, aWord)
      --appendValue(newText, " ")
      lineLength = indentLen + aWord:len() + 1
    else
      if i ~= 1 then appendValue(newText, " ") end
      appendValue(newText, aWord)
      lineLength = lineLength + aWord:len() + 1
    end
  end
  return table.concat(newText)
end

----------------------------------------------------------------------------------
-- The reWrapText.reWrapText function
--
local function reWrapText()
  local doc = getDoc()
  local firstLine, lastLine, _, blockCommentMarker, indentedCommentEnd =
    determineBlockStructure(doc)
  -- if we are on a blank line... move down one line
  if firstLine == nil then
    return moveCursorDownOneLine(doc)
  end

  -- gather the block of text
  local someLines = {}
  local curLine = firstLine
  while curLine <= lastLine do
    local curLineStr = doc.lines[curLine]
    local restOfStr  = curLineStr:sub(indentedCommentEnd)
    appendValue(someLines, restOfStr)
    curLine = curLine + 1
  end
  --
  -- determine the text width
  --
  local textWidth = doc.rewraptext.textWidth
  if textWidth == nil then
    textWidth = config.plugins.ReWrapText.textWidth
  end
  if textWidth == nil then
    textWidth = 75
  end
  --
  local lastLineStr = doc.lines[lastLine]
  if blockCommentMarker == nil then
    indentedCommentEnd = indentedCommentEnd - 1
  end
  local indentStr = lastLineStr:sub(1,indentedCommentEnd)
  -- now re-wrap the text
  local newText = reWrapWords(someLines, textWidth, indentStr)
  --
  -- Now replace the text
  --
  doc:remove(firstLine, 1, lastLine, #doc.lines[lastLine])
  doc:text_input(newText)
  moveCursorDownOneLine(doc)
end

----------------------------------------------------------------------------------
-- Initialize the reWrapText plugin
--
---@diagnostic disable-next-line: param-type-mismatch
command.add(nil, {
  ["rewraptext:selectCommentedBlock"] = selectCommentedBlock,
  ["rewraptext:commentBlock"]         = commentBlock,
  ["rewraptext:reWrapText"]           = reWrapText
})

keymap.add {
  ["alt+["] = 'rewraptext:selectCommentedBlock',
  ["alt+]"] = 'rewraptext:commentBlock',
  ["alt+j"] = 'rewraptext:reWrapText'
}

--  config.AddRuntimeFile("reWrapText", config.RTHelp, "help/reWrapText.md")

return ReWrapText

