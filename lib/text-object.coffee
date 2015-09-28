# Refactoring status: 95%
{Range} = require 'atom'
_    = require 'underscore-plus'
Base = require './base'
{
  selectLines
  isLinewiseRange
  rangeToBeginningOfFileFromPoint
  rangeToEndOfFileFromPoint
  isIncludeNonEmptySelection
  sortRanges
  setSelectionBufferRangeSafely
} = require './utils'

class TextObject extends Base
  @extend()
  complete: true

  isLinewise: ->
    @editor.getSelections().every (s) ->
      isLinewiseRange s.getBufferRange()

  eachSelection: (fn) ->
    fn(s) for s in @editor.getSelections()
    if @isLinewise() and not @vimState.isMode('visual', 'linewise')
      @vimState.activate('visual', 'linewise')
    @status()

  status: ->
    isIncludeNonEmptySelection @editor.getSelections()

  execute: ->
    @select()

# Word
# -------------------------
# [FIXME] Need to be extendable.
class Word extends TextObject
  @extend()
  select: ->
    @eachSelection (selection) =>
      wordRegex = @wordRegExp ? selection.cursor.wordRegExp()
      @selectExclusive(selection, wordRegex)
      @selectInclusive(selection) if @inclusive

  selectExclusive: (s, wordRegex) ->
    setSelectionBufferRangeSafely s, s.cursor.getCurrentWordBufferRange({wordRegex})

  selectInclusive: (selection) ->
    scanRange = selection.cursor.getCurrentLineBufferRange()
    headPoint = selection.getHeadBufferPosition()
    scanRange.start = headPoint
    @editor.scanInBufferRange /\s+/, scanRange, ({range, stop}) ->
      if headPoint.isEqual(range.start)
        selection.selectToBufferPosition range.end
        stop()

class WholeWord extends Word
  @extend()
  wordRegExp: /\S+/

# Pair
# -------------------------
class Pair extends TextObject
  @extend()
  inclusive: false
  pair: null

  isOpeningPair:(str, char) ->
    pattern = ///[^\\]?#{_.escapeRegExp(char)}///
    count = str.split(pattern).length - 1
    (count % 2) is 1

  isClosingPair:(str, char) ->
    not @isOpeningPair(str, char)

  needStopSearch: (pair, cursorRow, row) ->
    pair not in ["{}", "[]", "()"] and (cursorRow isnt row)

  findPair: (cursorPoint, fromPoint, pair, backward=false) ->
    pairChars = pair.split('')
    pairChars.reverse() unless backward
    [search, searchPair] = pairChars
    pairRegexp = pairChars.map(_.escapeRegExp).join('|')
    pattern   = ///(?:#{pairRegexp})///g

    [scanFunc, scanRange] =
      if backward
        ['backwardsScanInBufferRange', rangeToBeginningOfFileFromPoint(fromPoint)]
      else
        ['scanInBufferRange', rangeToEndOfFileFromPoint(fromPoint)]

    nest = 0
    found = null # We will search to fill this var.
    @editor[scanFunc] pattern, scanRange, ({matchText, range, stop}) =>
      charPre = @editor.getTextInBufferRange(range.traverse([0, -1], [0, -1]))
      return if charPre is '\\' # Skip escaped char with '\'
      {end, start} = range

      # don't search across line unless specific pair.
      return stop() if @needStopSearch(pair, cursorPoint.row, start.row)

      # [FIXME] aybe getting range within line and filter forwarding one afterward
      # is more decralative and easy to read.
      if search is searchPair
        if backward
          text = @editor.lineTextForBufferRow(fromPoint.row)
          found = end if @isOpeningPair(text[0..end.column], search)
        else # skip for pair not within cursorPoint.
          text = @editor.lineTextForBufferRow(fromPoint.row)
          if end.isGreaterThanOrEqual(cursorPoint)
            found = end if @isClosingPair(text[0..end.column], search)
          else
            stop()
      else
        switch matchText[matchText.length-1]
          when search then (if (nest is 0) then found = end else nest--)
          when searchPair then nest++
      stop() if found
    found

  getOpening: (cursorPoint, fromPoint, pair) ->
    @findPair(cursorPoint, fromPoint, pair, true)

  getClosing: (cursorPoint, fromPoint, pair) ->
    @findPair(cursorPoint, fromPoint, pair)?.traverse([0, -1])

  adjustRange: (range) ->
    if @inclusive
      range.translate([0, -1], [0, 1])
    else
      range

  getRangeWithinCursor: (cursorPoint, pair) ->
    p = cursorPoint
    range = null
    if (open = @getOpening(p, p, pair)) and (close = @getClosing(p, open, pair))
      range = @adjustRange(new Range(open, close))
    range

  getForwardRange: (cursorPoint, pair) ->
    p = cursorPoint
    range = null
    if (close = @getClosing(p, p, pair)) and (open = @getOpening(p, close, pair))
      range = @adjustRange(new Range(open, close))
    range

  pairsCanBeOutOfCursor = ['``', "''", '""']
  getRange: (selection, pair) ->
    selection.selectRight() if wasEmpty = selection.isEmpty()
    rangeOrig = selection.getBufferRange()
    point = selection.getHeadBufferPosition()

    if pair in pairsCanBeOutOfCursor and not @isAnyPair()
      range = @getRangeWithinCursor(point, pair) ? @getForwardRange(point, pair)
    else
      range = @getRangeWithinCursor(point, pair)
      if range?.isEqual(rangeOrig)
        # Since range is same area, retry to expand outer pair.
        point = range.start.translate([0, -1])
        range = @getRangeWithinCursor(point, pair)
    selection.selectLeft() if (not range) and wasEmpty
    range

  select: ->
    @eachSelection (s) =>
      setSelectionBufferRangeSafely s, @getRange(s, @pair)

class AnyPair extends Pair
  @extend()
  pairs: ['""', "''", "``", "{}", "<>", "><", "[]", "()"]

  getNearestRange: (selection, pairs) ->
    ranges = []
    for pair in pairs when (range = @getRange(selection, pair))
      ranges.push range
    _.last(sortRanges(ranges)) if ranges.length

  select: ->
    @eachSelection (s) =>
      setSelectionBufferRangeSafely s, @getNearestRange(s, @pairs)

class DoubleQuote extends Pair
  @extend()
  pair: '""'

class SingleQuote extends Pair
  @extend()
  pair: "''"

class BackTick extends Pair
  @extend()
  pair: '``'

class CurlyBracket extends Pair
  @extend()
  pair: '{}'

class AngleBracket extends Pair
  @extend()
  pair: '<>'

# [FIXME] See #795
class Tag extends Pair
  @extend()
  pair: '><'

class SquareBracket extends Pair
  @extend()
  pair: '[]'

class Parenthesis extends Pair
  @extend()
  pair: '()'

# Paragraph
# -------------------------
# In Vim world Paragraph is defined as consecutive (non-)blank-line.
class Paragraph extends TextObject
  @extend()

  getStartRow: (startRow, fn) ->
    for row in [startRow..0] when fn(row)
      return row+1
    0

  getEndRow: (startRow, fn) ->
    lastRow = @editor.getLastBufferRow()
    for row in [startRow..lastRow] when fn(row)
      return row
    lastRow+1

  getRange: (startRow) ->
    startRowIsBlank = @editor.isBufferRowBlank(startRow)
    fn = (row) =>
      @editor.isBufferRowBlank(row) isnt startRowIsBlank
    new Range([@getStartRow(startRow, fn), 0], [@getEndRow(startRow, fn), 0])

  selectParagraph: (selection) ->
    [startRow, endRow] = selection.getBufferRowRange()
    if startRow is endRow
      setSelectionBufferRangeSafely selection, @getRange(startRow)
    else # have direction
      if selection.isReversed()
        if range = @getRange(startRow-1)
          selection.selectToBufferPosition range.start
      else
        if range = @getRange(endRow+1)
          selection.selectToBufferPosition range.end

  selectExclusive: (selection) ->
    @selectParagraph(selection)

  selectInclusive: (selection) ->
    @selectParagraph(selection)
    @selectParagraph(selection)

  select: ->
    @eachSelection (selection) =>
      _.times @getCount(), =>
        if @inclusive
          @selectInclusive(selection)
        else
          @selectExclusive(selection)

class Comment extends Paragraph
  @extend()
  selectInclusive: (selection) ->
    @selectParagraph(selection)

  getRange: (startRow) ->
    return unless @editor.isBufferRowCommented(startRow)
    fn = (row) =>
      return if (@inclusive and @editor.isBufferRowBlank(row))
      @editor.isBufferRowCommented(row) in [false, undefined]
    new Range([@getStartRow(startRow, fn), 0], [@getEndRow(startRow, fn), 0])

class Indentation extends Paragraph
  @extend()
  selectInclusive: (selection) ->
    @selectParagraph(selection)

  getRange: (startRow) ->
    return if @editor.isBufferRowBlank(startRow)
    text = @editor.lineTextForBufferRow(startRow)
    baseIndentLevel = @editor.indentLevelForLine(text)
    fn = (row) =>
      if @editor.isBufferRowBlank(row)
        not @inclusive
      else
        text = @editor.lineTextForBufferRow(row)
        @editor.indentLevelForLine(text) < baseIndentLevel
    new Range([@getStartRow(startRow, fn), 0], [@getEndRow(startRow, fn), 0])

# TODO: make it extendable when repeated
class Fold extends TextObject
  @extend()
  getRowRangeForBufferRow: (bufferRow) ->
    for currentRow in [bufferRow..0] by -1
      [startRow, endRow] = @editor.languageMode.rowRangeForCodeFoldAtBufferRow(currentRow) ? []
      continue unless startRow? and startRow <= bufferRow <= endRow
      startRow += 1 unless @inclusive
      return [startRow, endRow]

  select: ->
    @eachSelection (selection) =>
      [startRow, endRow] = selection.getBufferRowRange()
      row = if selection.isReversed() then startRow else endRow
      if rowRange = @getRowRangeForBufferRow(row)
        selectLines(selection, rowRange)

# NOTE: Function range determination is depending on fold.
class Function extends Fold
  @extend()
  indentScopedLanguages: ['python', 'coffee']
  # FIXME: why go dont' fold closing '}' for function? this is dirty workaround.
  omitingClosingCharLanguages: ['go']

  getScopesForRow: (row) ->
    tokenizedLine = @editor.displayBuffer.tokenizedBuffer.tokenizedLineForRow(row)
    for tag in tokenizedLine.tags when tag < 0 and (tag % 2 is -1)
      atom.grammars.scopeForId(tag)

  functionScopeRegexp = /^entity.name.function/
  isIncludeFunctionScopeForRow: (row) ->
    for scope in @getScopesForRow(row) when functionScopeRegexp.test(scope)
      return true
    null

  # Greatly depending on fold, and what range is folded is vary from languages.
  # So we need to adjust endRow based on scope.
  getRowRangeForBufferRow: (bufferRow) ->
    for currentRow in [bufferRow..0] by -1
      [startRow, endRow] = @editor.languageMode.rowRangeForCodeFoldAtBufferRow(currentRow) ? []
      unless startRow? and (startRow <= bufferRow <= endRow) and @isIncludeFunctionScopeForRow(startRow)
        continue
      return @adjustRowRange(startRow, endRow)
    null

  adjustRowRange: (startRow, endRow) ->
    {scopeName} = @editor.getGrammar()
    languageName = scopeName.replace(/^source\./, '')
    unless @inclusive
      startRow += 1
      unless languageName in @indentScopedLanguages
        endRow -= 1
    endRow += 1 if (languageName in @omitingClosingCharLanguages)
    [startRow, endRow]

class CurrentLine extends TextObject
  @extend()
  select: ->
    @eachSelection (selection) =>
      {cursor} = selection
      cursor.moveToBeginningOfLine()
      cursor.moveToFirstCharacterOfLine() unless @inclusive
      selection.selectToEndOfLine()

class Entire extends TextObject
  @extend()
  select: ->
    @editor.selectAll()
    @status()

module.exports = {
  Word, WholeWord,
  DoubleQuote, SingleQuote, BackTick, CurlyBracket , AngleBracket, Tag,
  SquareBracket, Parenthesis,
  AnyPair
  Paragraph, Comment, Indentation,
  Fold, Function,
  CurrentLine, Entire,
}
