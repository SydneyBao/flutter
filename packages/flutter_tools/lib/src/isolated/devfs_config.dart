import 'dart:async';
import 'dart:io' as io;

import 'package:meta/meta.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

import '../base/common.dart';
import '../globals.dart' as globals;

@immutable
class DevConfig {
  const DevConfig({
    this.headers = const <String>[],
    this.host = 'localhost',
    this.port = 0,
    this.https,
    this.browser,
    this.experimentalHotReload,
    this.proxy = const <ProxyConfig>[],
  });

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

    final List<ProxyConfig> proxyRules = <ProxyConfig>[];
    if (yaml['proxy'] is YamlMap) {
      (yaml['proxy'] as YamlMap).forEach((dynamic key, dynamic value) {
        if (value is YamlMap) {
          proxyRules.add(ProxyConfig.fromYaml(key.toString(), value));
        }
      });
    }

    return DevConfig(
      headers: (yaml['headers'] as YamlList?)?.cast<String>() ?? const <String>[],
      host: yaml['host'] as String?,
      port: yaml['port'] as int?,
      https: yaml['https'] == null ? null : HttpsConfig.fromYaml(yaml['https'] as YamlMap),
      browser: yaml['browser'] == null ? null : BrowserConfig.fromYaml(yaml['browser'] as YamlMap),
      experimentalHotReload: yaml['experimental-hot-reload'] as bool?,
      proxy: proxyRules,
    );
  }

  final List<String> headers;
  final String? host;
  final int? port;
  final HttpsConfig? https;
  final BrowserConfig? browser;
  final bool? experimentalHotReload;
  final List<ProxyConfig> proxy;

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

  final String? certPath;
  final String? certKeyPath;

  @override
  String toString() {
    return '''
    HttpsConfig:
    certPath: $certPath
    certKeyPath: $certKeyPath''';
  }
}

abstract class ProxyConfig {
  ProxyConfig({required this.target, this.rewrite});
  
  factory ProxyConfig.fromYaml(String key, YamlMap yaml) {
    String Function(String)? rewriteFn;
    if (yaml['rewrite'] is bool && yaml['rewrite'] == true) {
      rewriteFn = (String path) => path.replaceFirst(key, '');
    } else {
      final String? rewriteValue = yaml['rewrite']?.toString();
      if (rewriteValue != null && rewriteValue.isNotEmpty) {
        final List<String> parts = rewriteValue.split('->');
        if (parts.length == 2) {
          final RegExp pattern = RegExp(parts[0].trim());
          final String replacementTemplate = parts[1].trim();

          rewriteFn = (String path) {
            final RegExpMatch? match = pattern.firstMatch(path);
            if (match != null) {
              String result = replacementTemplate;
              for (int i = 0; i <= match.groupCount; i++) {
                result = result.replaceAll('\$$i', match.group(i) ?? '');
              }
              return result;
            }
            return path;
          };
        }
      }
    }

    if (key.startsWith('^')) {
      try {
        return RegexProxyConfig(
          pattern: RegExp(key),
          target: yaml['target'] as String,
          rewrite: rewriteFn,
        );
      } on FormatException catch (e) {
        globals.printStatus('Warning: Invalid regex pattern "$key". Treating as string prefix: $e');
        return StringPrefixProxyConfig(
          prefix: key,
          target: yaml['target'] as String,
          rewrite: rewriteFn,
        );
      }
    } else {
      return StringPrefixProxyConfig(
        prefix: key,
        target: yaml['target'] as String,
        rewrite: rewriteFn,
      );
    }
  }

  final String target;
  final String Function(String)? rewrite;

  bool matches(String path);

  String getRewrittenPath(String path) {
    if (rewrite != null) {
      return rewrite!(path);
    }
    return path;
  }
}

class StringPrefixProxyConfig extends ProxyConfig {
  StringPrefixProxyConfig({required this.prefix, required super.target, super.rewrite});

  final String prefix;

  @override
  bool matches(String path) {
    return path.startsWith(prefix);
  }

  @override
  String toString() {
    return '{prefix: $prefix, target: $target, rewrite: ${rewrite != null ? 'yes' : 'no'}}';
  }
}

class RegexProxyConfig extends ProxyConfig {
  RegexProxyConfig({required this.pattern, required super.target, super.rewrite});

  final RegExp pattern;

  @override
  bool matches(String path) {
    return pattern.hasMatch(path);
  }

  @override
  String toString() {
    return '{pattern: ${pattern.pattern}, target: $target, rewrite: ${rewrite != null ? 'yes' : 'no'}}';
  }
}

@immutable
class BrowserConfig {
  
  /// Create a new [BrowserConfig] object.
  const BrowserConfig({required this.path, required this.args});

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

  final String? path;
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
  const String devConfigFilePath = 'web/devconfig.yaml';
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
    final YamlNode contents = yamlDoc.contents;
    if (contents is! YamlMap) {
      throw YamlException(
        'The root of $devConfigFilePath must be a YAML map (e.g., "server:"). '
        'Found a ${contents.runtimeType} instead.',
        contents.span,
      );
    }

    if (!contents.containsKey('server') || contents['server'] is! YamlMap) {
      // Find the span for the 'server' key if it exists but is malformed,
      // otherwise use the root span.
      final SourceSpan span =
          (contents.containsKey('server') && contents['server'] is YamlNode)
              ? (contents['server'] as YamlNode).span
              : contents.span;
      throw YamlException(
        'The "$devConfigFilePath" file is found, but the "server" key is '
        'missing or malformed. It must be a YAML map.',
        span,
      );
    }

    final YamlMap serverYaml = contents['server'] as YamlMap;
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

shelf.Middleware manageHeadersMiddleware({
  List<String> headersToInjectOnRequest = const <String>[],
  List<String> headersToRemoveFromRequest = const <String>[],
  Map<String, String> headersToSetOnResponse = const <String, String>{},
  List<String> headersToRemoveFromResponse = const <String>[],
}) {
  return (shelf.Handler innerHandler) {
    return (shelf.Request request) async {
      final Map<String, String> newRequestHeaders = Map<String, String>.of(request.headers);
      for (final String headerEntry in headersToInjectOnRequest) {
        final List<String> parts = headerEntry.split('=');
        if (parts.length == 2) {
          newRequestHeaders[parts[0].trim().toLowerCase()] = parts[1].trim();
        } else {
          globals.printError('Error in request header to inject: "$headerEntry"');
        }
      }
      for (final String headerNameToRemove in headersToRemoveFromRequest) {
        newRequestHeaders.remove(headerNameToRemove.toLowerCase());
      }
      final shelf.Request modifiedRequest = request.change(headers: newRequestHeaders);

      final shelf.Response response = await innerHandler(modifiedRequest);
      final Map<String, String> newResponseHeaders = Map<String, String>.of(response.headers);

      for (final String headerName in headersToRemoveFromResponse) {
        newResponseHeaders.remove(headerName.toLowerCase());
      }

      headersToSetOnResponse.forEach((String key, String value) {
        newResponseHeaders[key.toLowerCase()] = value;
      });
      return response.change(headers: newResponseHeaders);
    };
  };
}
