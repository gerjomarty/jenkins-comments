RestCaller = require('./rest_caller').RestCaller

class exports.GithubCaller extends RestCaller
  constructor: (user, repo, user_token, user_agent) ->
    super("https://api.github.com/#{@user}/#{@repo}", {access_token: user_token}, user_agent, null)
