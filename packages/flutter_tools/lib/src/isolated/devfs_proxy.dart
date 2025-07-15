// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:glob/glob.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_proxy/shelf_proxy.dart';
import 'package:yaml/yaml.dart';
import '/src/base/logger.dart';
import '../globals.dart' as globals;
import 'devfs_config.dart';

abstract class ProxyRule {
  ProxyRule({required this.target, this.headers});

  final String target;
  final YamlList? headers;
  String replace(String path);
  bool matches(String path);

  static ProxyRule? fromYaml(YamlMap yaml, {Logger? logger}) {
    final target = yaml['target'] as String?;
    final prefix = yaml['prefix'] as String?;
    final regex = yaml['regex'] as String?;
    final source = yaml['source'] as String?;
    final replace = yaml['replace'] as String?;
    final headers = yaml['headers'] as YamlList?;
    final Logger effectiveLogger = logger ?? globals.logger;

    if (target == null) {
      final String? path = prefix ?? regex;
      effectiveLogger.printError("Invalid 'target' for path: $path. 'target' cannot be null");
      return null;
    }

    if (prefix != null && prefix.isNotEmpty) {
      return PrefixProxyRule(
        prefix: prefix,
        target: target,
        replacement: replace?.trim(),
        headers: headers,
      );
    } else if (regex != null && regex.isNotEmpty) {
      RegExp? proxyPattern;
      try {
        proxyPattern = RegExp(regex.trim());
      } on FormatException catch (e) {
        proxyPattern = RegExp(RegExp.escape(regex));
        effectiveLogger.printWarning(
          "Invalid regex pattern in 'regex': '$regex'. Treating $regex as string. Error: $e",
        );
      }
      return RegexProxyRule(
        pattern: proxyPattern,
        target: target,
        replacement: replace?.trim(),
        headers: headers,
      );
    } else if (source != null && source.isNotEmpty) {
      Glob globPattern = Glob(source.trim());
      return GlobProxyRule(
        globPattern: globPattern,
        target: target,
        replacement: replace?.trim(),
        headers: headers,
      );
    } else {
      effectiveLogger.printError("'prefix', 'regex' or 'source' field must be provided");
      return null;
    }
  }
}

class RegexProxyRule extends ProxyRule {
  RegexProxyRule({required this.pattern, required super.target, this.replacement, super.headers});

  final RegExp pattern;
  final String? replacement;

  @override
  bool matches(String path) {
    return pattern.hasMatch(path);
  }

  @override
  String replace(String path) {
    if (replacement == null) {
      return path;
    }
    return path.replaceAllMapped(pattern, (Match match) {
      String result = replacement!;

      for (var i = 0; i <= match.groupCount; i++) {
        result = result.replaceAll('\$$i', match.group(i) ?? '');
      }
      return result;
    });
  }

  @override
  String toString() {
    return '{pattern: ${pattern.pattern}, target: $target, replacement: ${replacement ?? 'null'}}';
  }
}

class PrefixProxyRule extends ProxyRule {
  PrefixProxyRule({required this.prefix, required super.target, this.replacement, super.headers});
  final String prefix;
  final String? replacement;

  @override
  bool matches(String path) {
    return path.startsWith(prefix);
  }

  @override
  String replace(String path) {
    if (replacement == null) {
      return path;
    }
    return path.replaceFirst(prefix, replacement!);
  }

  @override
  String toString() {
    return '{prefix: $prefix, target: $target, replacement: ${replacement ?? 'null'}}';
  }
}

class GlobProxyRule extends ProxyRule {
  GlobProxyRule({
    required this.globPattern,
    required super.target,
    this.replacement,
    super.headers,
  });
  final Glob globPattern;
  final String? replacement;

  @override
  bool matches(String path) {
    return globPattern.matches(path);
  }

  @override
  String replace(String path) {
    if (replacement == null) {
      return path;
    }
    return path.replaceFirst(globPattern, replacement!);
  }

  @override
  String toString() {
    return '{source: $globPattern, target: $target, replacement: ${replacement ?? 'null'}}';
  }
}

shelf.Request proxyRequest(
  shelf.Request originalRequest,
  Uri finalTargetUrl,
  Map<String, String>? proxyRuleHeaders,
) {
  final Map<String, String> requestHeaders = Map.of(originalRequest.headers);
  if (proxyRuleHeaders != null) {
    requestHeaders.addAll(proxyRuleHeaders);
  }
  return shelf.Request(
    originalRequest.method,
    finalTargetUrl,
    headers: requestHeaders,
    body: originalRequest.read(),
    context: originalRequest.context,
  );
}

String _normalizePath(String path) {
  if (!path.startsWith('/')) {
    path = '/$path';
  }
  return path;
}

shelf.Middleware proxyMiddleware(List<ProxyRule> effectiveProxy) {
  return (shelf.Handler innerHandler) {
    return (shelf.Request request) async {
      final String requestPath = _normalizePath(request.url.path);
      for (final rule in effectiveProxy) {
        if (rule.matches(requestPath)) {
          final Uri targetBaseUri = Uri.parse(rule.target);
          final String rewrittenRequest = rule.replace(requestPath);
          final Uri finalTargetUrl = targetBaseUri.resolve(rewrittenRequest);
          final Map<String, String> ruleHeaders = getHeaders(rule.headers);
          try {
            final shelf.Request proxyBackendRequest = proxyRequest(
              request,
              finalTargetUrl,
              ruleHeaders,
            );
            final shelf.Response proxyResponse = await proxyHandler(targetBaseUri)(
              proxyBackendRequest,
            );
            final internalRequest = proxyResponse.headers['sec-fetch-mode'] == 'no-cors';
            if (!internalRequest) {
              globals.logger.printStatus(
                '[PROXY] Matched "$requestPath". Requesting "$finalTargetUrl"',
              );
              globals.logger.printTrace('[PROXY] Matched with proxy rule: $rule');
            }
            if (proxyResponse.statusCode == 404) {
              if (!internalRequest) {
                globals.printTrace('"$finalTargetUrl" responded with status 404');
              }
              return innerHandler(request);
            }
            return proxyResponse;
          } on Exception catch (e) {
            globals.logger.printError(
              'Proxy error for $finalTargetUrl: $e. Allowing fall-through.',
            );

            return innerHandler(request);
          }
        }
      }

      return innerHandler(request);
    };
  };
}
