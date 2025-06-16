import 'dart:async';
import 'package:package_config/package_config.dart';

import '../base/file_system.dart';
import '../base/logger.dart';
import '../dart/package_map.dart';
import '../globals.dart' as globals;
import '../web_template.dart';

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
