'use strict'


Inquirer = require('inquirer')
Ora = require('ora')
PutIO = require('put.io-v2')
cmdify = require('cmdify')
{concat} = require('lodash')
{execSync, spawn} = require('child_process')
{get} = require('request')
{yellow} = require('chalk')

MIME_DIR = 'application/x-directory'
PUTIO_URL = 'https://api.put.io/v2'


class Pio
  # add transfer(s)
  add: =>
    questions = [
      {
        message: 'URL:'
        name: 'url'
        type: 'input'
      }
      {
        default: no
        message: 'Extract after download?'
        name: 'extract'
        type: 'confirm'
      }
      {
        default: no
        message: 'Add another?'
        name: 'again'
        type: 'confirm'
      }
    ]

    Inquirer.prompt questions, (answers) =>
      {url, extract} = answers

      @uploads.push {url, extract}
      return @add() if answers.again

      @spinner.start()
      @api.transfers.add(upload.url, 0, upload.extract) for upload in @uploads
      @uploads = []
      @spinner.stop()
      @transfers()

    return


  # file browser
  browse: (retreat=no) =>
    @spinner.start()
    @log.shift() if retreat

    @api.files.list @log[0].id, (data) =>
      choices = []
      submenu = (@log.length > 1)

      choices.push(
        name: yellow(file.name)

        value:
          action: 'open'
          id: file.id
          name: file.name
          type: file.content_type
      ) for file in data.files

      files = [
        choices: @default(choices, submenu)
        message: 'Browse'
        name: 'files'
        type: 'list'
      ]

      @spinner.stop()

      Inquirer.prompt files, (answers) =>
        ans = answers.files

        switch ans.action
          when 'delete' then @delete()
          when 'menu' then @home()
          when 'move' then @move()
          when 'quit' then @quit(@browse)
          when 'rename' then @rename(@browse)

          when 'open'
            if ans.id?
              @log.unshift(ans)

              switch ans.type
                when MIME_DIR then @browse()
                else @file()

            else if submenu then @browse(yes)
            else @files()

    return


  # cancel transfer
  cancel: (id) =>
    neg = =>
      @transfer(id)
      return

    pos = =>
      @spinner.start()

      @api.transfers.cancel id, (result) =>
        @spinner.stop()
        @transfers()

      return

    @confirm pos, neg, 'Cancel?'
    return


  # confirm dialog mixin
  confirm: (positive, negative, message='Really?', defVal=no) =>
    confirm =
      type: 'confirm'
      name: 'confirm'
      default: defVal
      message: message

    Inquirer.prompt confirm, (answers) =>
      if answers.confirm then positive() else negative()

    return


  # default menu items
  default: (items, folder=no) =>
    header = [
      @item '← Back', 'open'
      new Inquirer.Separator()
    ]

    folderItems = [
      new Inquirer.Separator('─ Folder ─────')
      @item 'Move…', 'move'
      @item 'Rename…', 'rename'
      @item 'Delete…', 'delete'
    ]

    footer = [
      new Inquirer.Separator()
      @item '× Quit…', 'quit'
    ]

    unless folder then concat(header, items, footer)
    else concat(header, items, folderItems, footer)


  # delete file
  delete: =>
    del = =>
      @spinner.start()

      @api.files.delete @log[0].id, =>
        @spinner.stop()
        @browse yes

    @confirm del, @file, 'Delete?'
    return


  # file context menu
  file: =>
    items = [@item('Open', 'watch')]

    rest = [
      @item 'URL', 'display'
      @item 'Move…', 'move'
      @item 'Rename…', 'rename'
      @item 'Delete…', 'delete'
    ]

    prompt = (menu) =>
      questions = [
        choices: @default(menu)
        message: 'File'
        name: 'file'
        type: 'list'
      ]

      Inquirer.prompt questions, (answers) =>
        switch answers.file.action
          when 'display'
            @bar.updateBottomBar "\n#{@url()}\n\n"
            @file()

          when 'delete' then @delete()
          when 'download' then @spawn(yes)
          when 'move' then @move()
          when 'mp4' then @mp4()
          when 'open' then @browse(yes)
          when 'quit' then @quit(@file)
          when 'rename' then @rename(@file)
          when 'status' then @status()
          when 'transcode' then @make()
          when 'watch' then @spawn()

          else
            @bar.updateBottomBar "\n#{@url answers.file.action}\n\n"
            @file()

      return

    type = @log[0].type.split('/')

    if (type[0] is 'video') and (type[1] isnt 'mp4')
      @spinner.start()

      @status (response) =>
        # console.log JSON.stringify(response)
        return unless (response.status is 'OK')
        {mp4} = response

        items.push switch mp4.status
          when 'COMPLETED' then @item("MP4 (#{@size mp4.size})", 'mp4')
          when 'CONVERTING' then new Inquirer.Separator("Transcoding MP4… #{mp4.percent_done}%")
          when 'FINISHING' then new Inquirer.Separator("Finishing MP4…")
          when 'IN_QUEUE' then new Inquirer.Separator('Queued')
          when 'NOT_AVAILABLE' then @item('Transcode')
          else @item('MP4')

        @spinner.stop()
        prompt concat(items, rest)

    else if (type[1] is 'mp4')
      items.push @item('MP4')
      prompt concat(items, rest)

    else
      items.push @item('Download')
      prompt concat(items, rest)

    return


  # files submenu
  files: =>
    items = [
      choices: @default([
        @item 'Browse'
        @item 'Search…', 'search'
        @item 'New folder…', 'folder'
      ])

      message: 'Files'
      name: 'choice'
      type: 'list'
    ]

    Inquirer.prompt items, (answers) =>
      switch answers.choice.action
        when 'browse' then @browse()
        when 'folder' then @folder()
        when 'open' then @home()
        when 'quit' then @quit(@files)
        when 'search' then @files()

    return


  # create folder dialog
  folder: =>
    questions = [
      {
        default: 'New Folder'
        message: 'Name:'
        name: 'name'
        type: 'input'
      }
      {
        default: yes
        message: 'Create on root?'
        name: 'root'
        type: 'confirm'
      }
    ]

    Inquirer.prompt questions, (answers) =>
      create = (id) =>
        @spinner.start()

        @api.files.createFolder answers.name, id, (status) =>
          @spinner.stop()
          @files()

      if answers.root then create(0) else @pick(create)

    return


  # friend context menu
  friend: =>
    choices = [
      @item 'Display ID', 'display'
    ]

    questions = [
      choices: @default(choices)
      message: 'Friend'
      name: 'friend'
      type: 'list'
    ]

    Inquirer.prompt questions, (answers) =>
      switch answers.friend.action
        when 'display'
          @bar.updateBottomBar "\n#{ @log[0].id }\n\n"
          @friend()

        when 'open' then @friends(yes)
        when 'quit' then @quit(@friend)
        else console.log(answers.friend, @json())

    return


  # friends submenu
  friends: (retreat=no) =>
    items = []

    @log.shift() if retreat
    @spinner.start()

    @api.friends.list (friends) =>
      items.push(
        @item friend.name, 'view', id: friend.id
      ) for friend in friends.friends

      list = [
        choices: @default(items)
        message: 'Friends'
        name: 'friends'
        type: 'list'
      ]

      @spinner.stop()

      Inquirer.prompt list, (answers) =>
        ans = answers.friends

        switch ans.action
          when 'open' then @home()
          when 'quit' then @quit(@friends)

          when 'view'
            @log.unshift ans
            @friend()

    return


  # main menu
  home: ->
    items = [
      choices: [
        @item 'Files'
        @item 'Friends'
        @item 'Transfers'
        new Inquirer.Separator()
        @item '? Help'
        @item '§ Settings'
        @item '× Quit…', 'quit'
      ]
      message: 'Home'
      name: 'choice'
      type: 'list'
    ]

    Inquirer.prompt items, (answers) =>
      switch answers.choice.action
        when 'browse' then @browse()
        when 'files' then @files()
        when 'friends' then @friends()
        when 'transfers' then @transfers()

        when 'help'
          console.log '\nShowing Help\n'
          @home()

        when 'settings'
          console.log '\nShowing Settings\n'
          @home()

        when 'quit' then @quit(@home)

    return


  # transfer info
  info: (meta) =>
    json = JSON.stringify(meta)

    @bar.updateBottomBar "\n#{json}\n\n"
    @transfer(meta)
    return


  # menu item builder
  item: (name, action=null, extra={}) ->
    action = name.toLowerCase() unless action?
    value = Object.assign({action}, extra)

    return {name: yellow(name), value}


  # console.log + JSON.stringify
  json: (label='') =>
    console.log label, JSON.stringify(@log[0])
    return


  # transfer list
  list: =>
    xfers = []

    @spinner.start()

    @api.transfers.list (result) =>
      # console.log JSON.stringify(result)

      xfers.push(
        @item "[#{x.percent_done}%] [#{x.current_ratio}] #{x.name}", 'menu', meta: x
      ) for x in result.transfers

      menu = [
        choices: @default(xfers)
        message: 'Transfers'
        name: 'transfers'
        type: 'list'
      ]

      @spinner.stop()

      Inquirer.prompt menu, (answers) =>
        ans = answers.transfers

        switch ans.action
          when 'menu' then @transfer(ans.meta)
          when 'open' then @transfers()
          when 'quit' then @quit(@list)

    return


  # send transcode request
  make: =>
    console.log "make #{@log[0].id}"
    @spinner.start()

    @api.files.make_mp4 @log[0].id, =>
      @spinner.stop()
      @file()

    return


  # move
  move: =>
    @pick (id) =>
      @spinner.start()

      @api.files.move @log[0].id, id, =>
        @spinner.stop()
        @browse yes

    return


  # mp4 context menu
  mp4: =>
    ###
    files/xxx/put-mp4-to-my-folders
    var url = $(this).data('url') + "?login_token2=" + document.cookie.split("login_token2=")[1].split(";")[0];

    @item 'Download'
    @item 'Stream'
    ###

    items = [
      @item 'Download', 'mp4/download'
      @item 'Stream', 'mp4/stream'
      @item 'Add to folder', 'put-mp4-to-my-folders'
    ]

    menu = [
      choices: @default(items)
      message: 'Actions'
      name: 'actions'
      type: 'list'
    ]

    Inquirer.prompt menu, (answers) =>
      switch answers.actions.action
        when 'open' then @file()
        when 'quit' then @quit(@mp4)

        else
          @bar.updateBottomBar "\n#{@url(answers.actions.action)}\n\n"
          @mp4()

      return

    return


  # folder picker
  pick: (callback, ids=[0]) =>
    @spinner.start()

    @api.files.list ids[0], (data) =>
      choices = [
        @item '* Here', 'pick', here: yes, id: ids[0]
        new Inquirer.Separator()
      ]

      if (ids.length > 1)
        choices.splice 1, 0, @item('← Back', 'back', id: ids[1])

      choices.push(
        name: yellow(folder.name)

        value:
          action: 'pick'
          id: folder.id
          name: folder.name
          type: folder.content_type
      ) for folder in data.files when (folder.content_type is MIME_DIR)

      files = [
        choices: choices
        message: 'Target'
        name: 'pick'
        type: 'list'
      ]

      @spinner.stop()

      Inquirer.prompt files, (answers) =>
        {pick} = answers

        switch pick.action
          when 'back'
            ids.shift()
            @pick(callback, ids)

          when 'quit'
            @quit(@browse)

          when 'pick'
            # console.log "PICKED #{pick.id}"
            if pick.here? then callback(pick.id)
            else @pick(callback, concat([pick.id], ids))

        return
      return
    return


  # quit dialog
  quit: (callback) =>
    @confirm process.exit, callback, 'Quit?'
    return


  # read + display file
  read: (callback) =>
    get @url(), (error, response, body) =>
      @bar.updateBottomBar "\n#{body}\n"
      @spinner.stop()
      @browse yes

    return


  # rename file/folder
  rename: (callback) =>
    questions = [
      default: @log[0].name or ''
      message: 'Rename:'
      name: 'name'
      type: 'input'

      validate: (val) ->
        return 'Invalid name' unless val.trim().length
        return yes
    ]

    Inquirer.prompt questions, (answers) =>
      @spinner.start()

      @api.files.rename @log[0].id, answers.name, =>
        @spinner.stop()
        callback()


    return


  # setup wizard
  setup: =>
    questions = [
      {
        default: @config.downloads
        message: 'Download command:'
        name: 'download'
        type: 'input'
      }
      {
        default: @config.images
        message: 'Image view command:'
        name: 'images'
        type: 'input'
      }
      {
        default: @config.videos
        message: 'Video watch command:'
        name: 'videos'
        type: 'input'
      }
    ]

    Inquirer.prompt questions, (answers) =>
      @config = Object.assign(@config, answers)
      @home()

    return


  # get human-readable file size
  size: (bytes) ->
    exp = Math.log(bytes) / Math.log(1024) | 0
    result = (bytes / Math.pow(1024, exp)).toFixed(2)
    suffix = if (exp is 0) then 'bytes' else "#{'KMGTPEZY'[exp - 1]}B"

    return "#{result} #{suffix}"


  # spawn external process
  spawn: (download=no, action='download') =>
    launch = (template) =>
      render = (cmd=template) =>
        cmd.split('%name').join(@log[0].name).split('%url').join(@url(action))

      unless download
        cmd = spawn(render(), [@url(action)], stdio: 'pipe')
        cmd.stdout.pipe(@bar.log)
      else execSync(render @config.downloads)

      @browse yes

    switch @log[0].type.split('/')[0]
      when 'image' then launch(@config.images)
      when 'text' then @read()
      when 'video' then launch(@config.videos)
      else @home()

    return


  # transcode mp4 status
  status: (callback) =>
    @api.files.get_mp4 @log[0].id, callback
    return


  # transcode mp4
  transcode: =>
    @spinner.start()

    @status (response) =>
      @spinner.stop()

      return unless (response.status is 'OK')
      {mp4} = response

      switch mp4.status
        when 'COMPLETED'
          show = =>
            @bar.updateBottomBar "\n#{@url()}\n\n"
            @file()

          @bar.updateBottomBar "\nStatus: #{mp4.status} (#{mp4.size} bytes)\n\n"
          @confirm(show, @file, 'Show URL?', yes)

        when 'NOT_AVAILABLE'
          @bar.updateBottomBar "\nStatus: #{mp4.status}\n\n"
          @confirm(@make, @file, 'Transcode?', yes)

        else
          #'IN_QUEUE', 'PREPARING', 'CONVERTING', 'FINISHING'
          @bar.updateBottomBar "\nStatus: #{mp4.status} [#{mp4.percent_done}%]\n\n"
          @file()

    return


  # transfer context menu
  transfer: (meta) =>
    items = [
      @item 'Details', 'info', meta: meta
      @item 'Cancel…', 'cancel', id: meta.id
    ]

    menu = [
      choices: @default(items)
      message: 'Transfer'
      name: 'transfer'
      type: 'list'
    ]

    Inquirer.prompt menu, (answers) =>
      ans = answers.transfer

      switch ans.action
        when 'cancel' then @cancel(ans.id)
        when 'info' then @info(meta)
        when 'open' then @transfers()
        when 'quit' then @quit(@transfer)

    return


  # transfers submenu
  transfers: =>
    items = [
      @item 'List'
      @item 'Add…'
    ]

    menu = [
      choices: @default(items)
      message: 'Transfers'
      name: 'transfers'
      type: 'list'
    ]

    Inquirer.prompt menu, (answers) =>
      switch answers.transfers.action
        when 'add…' then @add()
        when 'list' then @list()
        when 'open' then @home()
        when 'quit' then @quit(@transfers)

    return


  # return a proper url
  url: (action='download') =>
    switch action
      when 'download' then @api.files.download(@log[0].id)
      else "#{PUTIO_URL}/files/#{@log[0].id}/#{action}?oauth_token=#{@token}"


  # class constructor
  constructor: (@token) ->
    @config =
      downloads: 'wget -c %url -O /mnt/incomplete/%name'
      images: 'feh %url'
      videos: 'mpv %url'

    @api = new PutIO(@token)
    @bar = new Inquirer.ui.BottomBar
    @log = [id:0]
    @uploads = []

    ###
    rnd = ->
      r = 1 + Math.round(Math.random() * 10)
      console.log r
      if r is 1 then '' else r
    ###

    @spinner = Ora(
      color: 'yellow'
      spinner: 'dots2'# + rnd()
      stream: process.stdout
      text: 'Loading…'
    )


module.exports = Pio
