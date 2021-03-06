http = require('http')
q = require('q')
_ = require('lodash')
express = require('express')
parseRange = require('range-parser')

{random32, Hasher} = require('../../utils')
serverUtils = require('./server-utils')

MD5_EMPTY = 'd41d8cd98f00b204e9800998ecf8427e'

class SwiftServer
  constructor: (swift) ->
    @options = swift.options

    common = (req, res, next) ->
      if swift.options.verbose
        originalEnd = res.end

        res.end = (data) ->
          console.log req.method, req.url, res.statusCode

          originalEnd.call(res, data)

      res.lines = (list) ->
        res.set 'Content-Type', 'text/plain; charset=utf-8'
        res.send list.map((x) -> x + '\n').join('')

      res.set 'X-Trans-Id', 'tx' + random32()

      res.timestamp = (date) ->
        date = new Date() if not date?
        res.set 'X-Timestamp', date.getTime() / 1000

      req.json = serverUtils.reqIsJson(req)

      req.head = req.method == 'HEAD'

      req.account = req.param('account')
      req.container = req.param('container')
      req.object = req.param(0)

      authToken = req.get('x-auth-token')

      authAccount = if authToken
        swift.getAuthTokenAccount(authToken)
      else
        q(null)

      getContainer = ->
        swift.getContainer(req.account, req.container)

      result = serverUtils.authorize(req, res, authAccount, getContainer).then ->
        next()

      result.fail (err) ->
        # e.g. throw res.send(404)
        if not err.statusCode?
          if process.env.DEBUG
            process.nextTick ->
              console.dir err
              throw err
          else
            console.error(err)
            console.error(err.stack)

          res.send 500

    app = express()

    app.disable('x-powered-by')
    app.use(app.router)

    app.get '/auth/v1.0*', (req, res) ->
      user = req.get('x-auth-user') or req.get('x-storage-user')
      key = req.get('x-auth-key') or req.get('x-storage-pass')

      swift.authenticate(user, key).then((authenticated) ->
        if authenticated
          account = user.split(':')[0]

          swift.newAuthToken(account).then (authToken) ->
            host = req.get('host')

            res.set 'X-Storage-Url', "http://#{host}/v1/AUTH_#{account}"
            res.set 'X-Auth-Token', authToken
            res.set 'X-Storage-Token', authToken

            res.send 200
        else
          res.send 401
      ).fail((err) ->
        console.error(err)
        console.error(err.stack)
        res.send 500
      )

    app.get '/v1/AUTH_:account', common, (req, res) ->
      swift.getAccount(req.account).then (accountInfo) ->
        swift.getContainers(req.account).then (containerInfos) ->
          containers = _.pairs(containerInfos).map ([name, info]) ->
            name: name
            count: info.objectCount
            bytes: info.bytesUsed

          res.set 'X-Account-Bytes-Used', accountInfo.bytesUsed
          res.set 'X-Account-Container-Count', accountInfo.containerCount
          res.set 'X-Account-Object-Count', accountInfo.objectCount

          res.timestamp(accountInfo.lastModified)

          serverUtils.attachMetadata(accountInfo.metadata, res, 'account')

          if req.param('marker')?
            containers = []

          if req.head
            return res.send(204)

          if req.json
            res.json containers
          else
            if containers.length == 0
              res.statusCode = 204

            res.lines containers.map((x) -> x.name)

    app.post '/v1/AUTH_:account', common, (req, res) ->
      swift.getAccount(req.account).then (accountInfo) ->
        md = serverUtils.extractMetadata(req.headers, 'account')

        swift.mergeAccountMetadata(req.account, md).then ->
          res.send 204

    app.put '/v1/AUTH_:account', common, (req, res) ->
      res.send 403

    app.delete '/v1/AUTH_:account', common, (req, res) ->
      res.send 403

    app.get '/v1/AUTH_:account/:container', common, (req, res) ->
      swift.getContainer(req.account, req.container).then (containerInfo) ->
        if not containerInfo?
          return res.send 404

        swift.getObjects(req.account, req.container).then (objects) ->
          res.set 'X-Container-Bytes-Used', containerInfo.bytesUsed
          res.set 'X-Container-Object-Count', containerInfo.objectCount

          res.timestamp(containerInfo.lastModified)

          serverUtils.attachMetadata(containerInfo.metadata, res, 'container')
          serverUtils.attachAcl(containerInfo.acl, res)

          if req.head
            return res.send(204)

          prefix = req.param('prefix')
          delimiter = req.param('delimiter')
          path = req.param('path')

          marker = req.param('marker')
          marker = null if not marker

          endMarker = req.param('end_marker')
          endMarker = null if not endMarker

          limit = req.param('limit')
          limit = if limit then Number(limit) else null
          limit = null if limit? and (isNaN(limit) or limit < 0)

          objsMeta = serverUtils.formatObjects(objects, prefix, delimiter, path, marker, endMarker, limit)

          if req.json
            res.json objsMeta
          else
            if objsMeta.length == 0
              res.statusCode = 204

            res.lines _.map(objsMeta, (x) -> x.name or x.subdir)

    app.put '/v1/AUTH_:account/:container', common, (req, res) ->
      swift.getContainer(req.account, req.container).then (containerInfo) ->
        acl = serverUtils.extractAcl(req.headers)

        if not containerInfo?
          md = serverUtils.extractMetadata(req.headers, 'container')

          swift.addContainer(req.account, req.container, md, acl).then ->
            res.send 201
        else
          swift.mergeContainerAcl(req.account, req.container, acl).then ->
            res.send 202

    app.post '/v1/AUTH_:account/:container', common, (req, res) ->
      swift.getContainer(req.account, req.container).then (containerInfo) ->
        if containerInfo?
          md = serverUtils.extractMetadata(req.headers, 'container')
          acl = serverUtils.extractAcl(req.headers)

          swift.mergeContainerMetadata(req.account, req.container, md).then ->
            swift.mergeContainerAcl(req.account, req.container, acl).then ->
              res.send 204
        else
          res.send 404

    app.delete '/v1/AUTH_:account/:container', common, (req, res) ->
      swift.getContainer(req.account, req.container).then (containerInfo) ->
        if containerInfo?
          if swift.canDeleteContainer(containerInfo)
            swift.deleteContainer(req.account, req.container).then ->
              res.send 204
          else
            res.send 409
        else
          res.send 404

    app.get '/v1/AUTH_:account/:container/*', common, (req, res) ->
      swift.getObject(req.account, req.container, req.object).then (obj) ->
        if not obj?
          return res.send 404

        res.set 'Accept-Ranges', 'bytes'
        res.set 'Content-Type', obj.contentType
        res.set 'Last-Modified', obj.lastModified.toUTCString()
        res.set 'Etag', obj.hash

        res.timestamp(obj.lastModified)

        serverUtils.attachMetadata(obj.metadata, res)

        segments = null

        if obj.objectManifest
          manifestParts = obj.objectManifest.split('/')
          container = manifestParts.shift()
          manifest = manifestParts.join('/')

          segments = swift.getContainer(req.account, container).then (containerInfo) ->
            if not containerInfo
              throw res.send(404)

            swift.getObjects(req.account, container).then (objects) ->
              res.set 'X-Object-Manifest', obj.objectManifest

              manifestLength = manifest.length

              segs = _(objects).pairs()
                .filter(([name, seg]) -> name.indexOf(manifest) == 0)
                .sortBy(([name, seg]) -> name.slice(manifestLength))
                .map(([name, seg]) -> seg)

              hashes = segs.map (x) -> x.hash
              etag = Hasher.hashArray(hashes)

              res.set 'Etag', '"' + etag + '"'

              segs
        else
          segments = q([obj])

        segments.then (segments) ->
          contentLength = segments
            .map((x) -> x.contentLength)
            .reduce(((x, y) -> x + y), 0)

          if req.head
            res.set 'Content-Length', contentLength
            return res.end()

          range =
            start: 0
            end: contentLength - 1

          if req.headers.range
            parsedRange = parseRange(contentLength, req.headers.range)

            if parsedRange == -1
              res.set 'Content-Range', 'bytes */' + contentLength
              return res.send(416)

            if parsedRange != -2
              range =
                start: parsedRange[0].start
                end: parsedRange[0].end

              res.statusCode = 206
              res.set 'Content-Range', "bytes #{range.start}-" +
                "#{range.end}/#{contentLength}"

          currentLength = range.end - range.start + 1

          res.set 'Content-Length', currentLength

          offset = 0

          next = ->
            segment = segments.shift()

            if segment?
              segmentLength = segment.contentLength

              if range.start <= (offset + segmentLength) and range.end >= offset
                segmentRange =
                  start: Math.max(range.start - offset, 0)
                  end: Math.min(range.end - offset, segmentLength - 1)

                swift.objectStream(segment, segmentRange).then (stream) ->
                  stream.pipe(res, end: no)

                  stream.on 'end', ->
                    stream.unpipe(res)

                    offset += segmentLength

                    next()
              else
                offset += segmentLength

                next()
            else
              res.end()

          next()

    app.put '/v1/AUTH_:account/:container/*', common, (req, res) ->
      metadata = serverUtils.extractMetadata(req.headers)

      copyFrom = req.get('x-copy-from')

      if req.get('content-length') == '0' and copyFrom
        ci = serverUtils.parseCopyPath(copyFrom)

        return res.send(412) if not ci?
        return res.send(400) if not ci.object

        return swift.getObject(req.account, ci.container, ci.object).then (obj) ->
          if not obj?
            return res.send 404

          obj = _.cloneDeep(obj)

          if req.get('content-type')
            obj.contentType = req.get('content-type')

          if req.get('x-object-manifest')
            obj.objectManifest = req.get('x-object-manifest')

          if _.keys(metadata).length
            obj.metadata = metadata

          swift.copyObject(req.account, req.container, req.object, obj).then (obj) ->
            res.set 'Etag', obj.hash
            res.send 201

      obj =
        contentType: req.get('content-type')
        objectManifest: req.get('x-object-manifest')
        hash: req.get('etag')

      if _.keys(metadata).length
        obj.metadata = metadata

      if obj.objectManifest and obj.hash and obj.hash != MD5_EMPTY
        return res.send(503)

      swift.createObject(req.account, req.container, req.object, obj, req).then((obj) ->
        res.set 'Etag', obj.hash
        res.send 201
      ).fail((err) ->
        if err instanceof swift.BadHashError
          res.send 422
        else
          throw err
      )

    app.copy '/v1/AUTH_:account/:container/*', common, (req, res) ->
      swift.getObject(req.account, req.container, req.object).then (obj) ->
        return res.send 404 if not obj?

        return res.send 412 if not req.get('destination')

        copyInfo = serverUtils.parseCopyPath(req.get('destination'))

        return res.send 412 if not copyInfo?
        return res.send 503 if not copyInfo.object

        swift.getContainer(req.account, copyInfo.container).then (containerInfo) =>
          return res.send 404 if not containerInfo?

          metadata = serverUtils.extractMetadata(req.headers)

          obj = _.cloneDeep(obj)

          if req.get('content-type')
            obj.contentType = req.get('content-type')

          if req.get('x-object-manifest')
            obj.objectManifest = req.get('x-object-manifest')

          if _.keys(metadata).length
            obj.metadata = metadata

          swift.copyObject(req.account, copyInfo.container, copyInfo.object, obj).then ->
            res.send 201

    app.post '/v1/AUTH_:account/:container/*', common, (req, res) ->
      md = serverUtils.extractMetadata(req.headers)

      swift.setObjectMetadata(req.account, req.container, req.object, md).then ->
        res.send 202

    app.delete '/v1/AUTH_:account/:container/*', common, (req, res) ->
      swift.getObject(req.account, req.container, req.object).then (obj) ->
        if obj?
          swift.deleteObject(req.account, req.container, req.object).then ->
            res.send 204
        else
          res.send 404

    @app = app

  listen: =>
    @httpServer = http.createServer(@app)

    @httpServer.listen(@options.port)

  close: =>
    @httpServer?.close()

module.exports = SwiftServer
