import 'dart:async';
import 'dart:io' as io;

import 'package:meta/meta.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

import '../base/common.dart';
import '../globals.dart' as globals;

/// Class that represents the web server configuration specified in a `devconfig.yaml` file.
@immutable
class DevConfig {
  /// Create a new [DevConfig] object.
  const DevConfig({
    this.headers = const <String>[],
    this.host = 'localhost',
    this.port = 0,
    this.https,
    this.browser,
    this.experimentalHotReload,
    this.proxy = const <String, ProxyConfig>{},
  });

  /// Create a [DevConfig] from a `server` YAML map.
  factory DevConfig.fromYaml(YamlMap yaml) {
    if (yaml['host'] is! String && yaml['host'] != null) {
      throwToolExit('Host must be a String. Found ${yaml['host'].runtimeType}');
    }
    if (yaml['port'] is! int && yaml['port'] != null) {
      throwToolExit('Port must be an int. Found ${yaml['port'].runtimeType}');
    }
    if (yaml['headers'] is! YamlList && yaml['headers'] != null) {
      throwToolExit('Headers must be a List<String>. Found ${yaml['headers'].runtimeType}');
    }
    if (yaml['https'] is! YamlMap && yaml['https'] != null) {
      throwToolExit('Https must be a Map. Found ${yaml['https'].runtimeType}');
    }
    if (yaml['browser'] is! YamlMap && yaml['browser'] != null) {
      throwToolExit('Browser must be a Map. Found ${yaml['browser'].runtimeType}');
    }
    if (yaml['experimental-hot-reload'] is! bool && yaml['experimental-hot-reload'] != null) {
      throwToolExit(
        'experimental-hot-reload must be a bool. Found ${yaml['experimental-hot-reload'].runtimeType}',
      );
    }
    if (yaml['proxy'] is! YamlMap && yaml['proxy'] != null) {
      throwToolExit('proxy must be a Map. Found ${yaml['proxy'].runtimeType}');
    }

    return DevConfig(
      headers: (yaml['headers'] as YamlList?)?.cast<String>() ?? const <String>[],
      host: yaml['host'] as String?,
      port: yaml['port'] as int?,
      https: yaml['https'] == null ? null : HttpsConfig.fromYaml(yaml['https'] as YamlMap),
      browser: yaml['browser'] == null ? null : BrowserConfig.fromYaml(yaml['browser'] as YamlMap),
      experimentalHotReload: yaml['experimental-hot-reload'] as bool?,
      proxy: <String, ProxyConfig>{
        for (final MapEntry<dynamic, dynamic> entry
            in (yaml['proxy'] as YamlMap? ?? <dynamic, dynamic>{}).entries)
          if (entry.key is String && entry.value is YamlMap)
            entry.key as String: ProxyConfig.fromYaml(entry.value as YamlMap),
      },
    );
  }

  final List<String> headers;
  final String? host;
  final int? port;
  final HttpsConfig? https;
  final BrowserConfig? browser;
  final bool? experimentalHotReload;
  final Map<String, ProxyConfig> proxy;

  @override
  String toString() {
    return '''
  DevConfig:
  headers: $headers
  host: $host
  port: $port
  https: $https
  browser: $browser
  experimentalHotReload: $experimentalHotReload
  proxy: $proxy''';
  }
}

/// HTTPS configuration for the web server.
@immutable
class HttpsConfig {
  /// Create a new [HttpsConfig] object.
  const HttpsConfig({required this.certPath, required this.certKeyPath});

  /// Create a [HttpsConfig] from a `https` YAML map.
  factory HttpsConfig.fromYaml(YamlMap yaml) {
    if (yaml['cert-path'] is! String && yaml['cert-path'] != null) {
      throwToolExit('Https cert-path must be a String. Found ${yaml['cert-path'].runtimeType}');
    }
    if (yaml['cert-key-path'] is! String && yaml['cert-key-path'] != null) {
      throwToolExit(
        'Https cert-key-path must be a String. Found ${yaml['cert-key-path'].runtimeType}',
      );
    }
    return HttpsConfig(
      certPath: yaml['cert-path'] as String?,
      certKeyPath: yaml['cert-key-path'] as String?,
    );
  }

  /// The path to the SSL certificate.
  final String? certPath;

  /// The path to the SSL certificate key.
  final String? certKeyPath;

  @override
  String toString() {
    return '''
    HttpsConfig:
    certPath: $certPath
    certKeyPath: $certKeyPath''';
  }
}

/// Proxy configuration for the web server.
@immutable
class ProxyConfig {
  const ProxyConfig({required this.target});

  factory ProxyConfig.fromYaml(YamlMap yaml) {
    return ProxyConfig(target: yaml['target'] as String);
  }

  final String target;

  @override
  String toString() {
    return '{target: $target}';
  }
}

/// Browser configuration for the web server.
@immutable
class BrowserConfig {
  /// Create a new [BrowserConfig] object.
  const BrowserConfig({required this.path, required this.args});

  /// Create a [BrowserConfig] from a `browser` YAML map.
  factory BrowserConfig.fromYaml(YamlMap yaml) {
    if (yaml['path'] is! String && yaml['path'] != null) {
      throwToolExit('Browser path must be a String. Found ${yaml['path'].runtimeType}');
    }
    if (yaml['args'] is! YamlList && yaml['args'] != null) {
      throwToolExit('Browser args must be a List<String>. Found ${yaml['args'].runtimeType}');
    }
    return BrowserConfig(
      path: yaml['path'] as String?,
      args: (yaml['args'] as YamlList?)?.cast<String>() ?? <String>[],
    );
  }

  /// The path to the browser executable.
  final String? path;

  /// The arguments to pass to the browser executable.
  final List<String> args;

  @override
  String toString() {
    return '''
    BrowserConfig:
    path: $path
    args: $args''';
  }
}

/// Loads the web server configuration from `devconfig.yaml`.
///
/// If `devconfig.yaml` is not found or cannot be parsed, it returns a [DevConfig]
/// with default values.
Future<DevConfig> loadDevConfig() async {
  const String devConfigFilePath = 'devconfig.yaml';
  final io.File devConfigFile = globals.fs.file(devConfigFilePath);

  if (!devConfigFile.existsSync()) {
    globals.printStatus(
      'No $devConfigFilePath found. Running with default web server configuration.',
    );
    return const DevConfig();
  }

  try {
    final String devConfigContent = await devConfigFile.readAsString();
    final YamlDocument yamlDoc = loadYamlDocument(devConfigContent);
    final YamlNode? contents = yamlDoc.contents;

    if (contents is! YamlMap) {
      final SourceSpan span;
      if (contents != null) {
        span = contents.span;
      } else {
        final SourceFile sourceFile = SourceFile.fromString(
          devConfigContent,
          url: Uri.file(devConfigFilePath),
        );
        span = sourceFile.span(0, devConfigContent.length);
      }

      throw YamlException(
        'The root of $devConfigFilePath must be a YAML map (e.g., "server:"). '
        'Found a ${yamlDoc.contents.runtimeType} instead.',
        span,
      );
    }
    final YamlMap rootYaml = yamlDoc.contents as YamlMap;

    if (!rootYaml.containsKey('server') || rootYaml['server'] is! YamlMap) {
      // Find the span for the 'server' key if it exists but is malformed,
      // otherwise use the root span.
      final SourceSpan span =
          (rootYaml.containsKey('server') && rootYaml['server'] is YamlNode)
              ? (rootYaml['server'] as YamlNode).span
              : rootYaml.span;

      throw YamlException(
        'The "$devConfigFilePath" file is found, but the "server" key is '
        'missing or malformed. It must be a YAML map.',
        span,
      );
    }

    final YamlMap serverYaml = rootYaml['server'] as YamlMap;
    final DevConfig config = DevConfig.fromYaml(serverYaml);
    globals.printStatus('\nParsed devconfig.yaml:');
    globals.printStatus(config.toString());

    if (config.proxy.isNotEmpty) {
      globals.printStatus(
        'Initializing web server with custom configuration. Found ${config.proxy.length} proxy rules.',
      );
    } else {
      globals.printStatus('No proxy rules found.');
    }
    return config;
  } on YamlException catch (e) {
    String errorMessage = 'Error: Failed to parse $devConfigFilePath: ${e.message}';
    if (e.span != null) {
      errorMessage += '\n  At line ${e.span!.start.line + 1}, column ${e.span!.start.column + 1}';
      errorMessage += '\n  Problematic text: "${e.span!.text}"';
    }
    globals.printError(errorMessage);
    rethrow;
  } on Exception catch (e) {
    globals.printError('An unexpected error occurred while reading devconfig.yaml: $e');
    globals.printStatus(
      'Reverting to default flutter_tools web server configuration due to unexpected error.',
    );
    return const DevConfig();
  }
}

shelf.Middleware injectHeadersMiddleware(List<String> headersToInject) {
  return (shelf.Handler innerHandler) {
    return (shelf.Request request) async {
      final Map<String, String> newHeaders = Map<String, String>.of(request.headers);

      for (final String headerEntry in headersToInject) {
        final List<String> parts = headerEntry.split('=');
        if (parts.length == 2) {
          newHeaders[parts[0].toLowerCase()] = parts[1];
        } else {
          globals.printError('Error in header: "$headerEntry"');
        }
      }
      final shelf.Request modifiedRequest = request.change(headers: newHeaders);

      // print('--- Request Headers After Middleware Injection ---');
      // newHeaders.forEach((key, value) {
      //   print('$key: $value');
      // });
      // print('----------------------------------------------------');

      return await innerHandler(modifiedRequest);
    };
  };
}
