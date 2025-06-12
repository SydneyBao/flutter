import 'dart:async';
import 'package:package_config/package_config.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_proxy/shelf_proxy.dart';

import '../base/file_system.dart';
import '../base/logger.dart';
import '../dart/package_map.dart';
import '../globals.dart' as globals;
import '../web_template.dart';
import 'devfs_config.dart';

const String kDefaultIndex = '''
<html>
    <head>
        <meta charset='utf-8'>
        <base href="/">
    </head>
    <body>
        <script src="main.dart.js"></script>
    </body>
</html>
''';

String? stripBasePath(String path, String basePath) {
  path = stripLeadingSlash(path);
  if (path.startsWith(basePath)) {
    path = path.substring(basePath.length);
  } else {
    // The given path isn't under base path, return null to indicate that.
    return null;
  }
  return stripLeadingSlash(path);
}

WebTemplate getWebTemplate(String filename, String fallbackContent) {
  final String htmlContent = htmlTemplate(filename, fallbackContent);
  return WebTemplate(htmlContent);
}

String htmlTemplate(String filename, String fallbackContent) {
  final File template = globals.fs.currentDirectory.childDirectory('web').childFile(filename);
  return template.existsSync() ? template.readAsStringSync() : fallbackContent;
}

Future<Directory> loadDwdsDirectory(FileSystem fileSystem, Logger logger) async {
  final PackageConfig packageConfig = await currentPackageConfig();
  return fileSystem.directory(packageConfig['dwds']!.packageUriRoot);
}

shelf.Middleware proxyMiddleware(List<ProxyConfig> effectiveProxy) {
  return (shelf.Handler innerHandler) {
    return (shelf.Request request) async {
      bool isWebSocketUpgrade(shelf.Request request) {
        final String connectionHeader = request.headers['Connection']?.toLowerCase() ?? '';
        return connectionHeader.contains('upgrade') &&
            request.headers['Upgrade']?.toLowerCase() == 'websocket';
      }

      final String requestPath = '/${request.url.path}'.replaceAll('//', '/');
      for (final ProxyConfig config in effectiveProxy) {
        if (config.matches(requestPath)) {
          if (isWebSocketUpgrade(request)) {
            globals.printWarning('WebSockets not supported by proxy: $requestPath');
            return innerHandler(request);
          }
          final Uri targetBaseUri = Uri.parse(config.target);
          final String rewrittenRequest = config.getRewrittenPath(requestPath);
          final Uri finalTargetUrl = targetBaseUri.resolve(rewrittenRequest);
          try {
            final shelf.Request proxyBackendRequest = shelf.Request(
              request.method,
              finalTargetUrl,
              headers: request.headers,
              body: request.read(),
              context: request.context,
            );
            return await proxyHandler(targetBaseUri)(proxyBackendRequest);
          } on Exception catch (e) {
            globals.printError('Proxy error for $finalTargetUrl: $e. Allowing fall-through.');
            return innerHandler(request);
          }
        }
      }
      return innerHandler(request);
    };
  };
}
