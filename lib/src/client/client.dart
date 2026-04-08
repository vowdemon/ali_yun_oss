import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:dart_aliyun_oss/src/client/impl/delete_object_impl.dart';
import 'package:dart_aliyun_oss/src/config/config.dart';
import 'package:dart_aliyun_oss/src/interfaces/service.dart';
import 'package:dart_aliyun_oss/src/interfaces/sign_strategy.dart';
import 'package:dart_aliyun_oss/src/models/models.dart';
import 'package:dart_aliyun_oss/src/strategy/strategy.dart';
import 'package:dart_aliyun_oss/src/utils/utils.dart';
import 'package:dio/dio.dart';

import 'impl/abort_multipart_upload_impl.dart';
import 'impl/complete_multipart_upload_impl.dart';
import 'impl/get_object_impl.dart';
import 'impl/initiate_multipart_upload_impl.dart';
import 'impl/list_multipart_uploads_impl.dart';
import 'impl/list_objects_v2_impl.dart';
import 'impl/list_parts_impl.dart';
import 'impl/multipart_upload_impl.dart';
import 'impl/put_object_impl.dart';
import 'impl/signed_url_impl.dart';
import 'impl/upload_part_impl.dart';
import 'request_handler.dart';
import 'request_manager.dart';

/// 阿里云OSS客户端
///
/// 实现了 [IOSSService] 接口,提供OSS基础操作,包括：
/// - 获取对象（下载文件）
/// - 上传对象（上传文件）
/// - 分片上传相关操作 (初始化、上传分片、完成、中止、列出分片、列出上传事件)
/// - 高级分片上传（自动处理分片逻辑,支持并发）
/// - 生成签名URL（用于临时授权访问）
/// - 请求取消管理
///
/// 主要特性：
/// - 多实例模式：每个 [OSSClient] 实例持有独立配置，可连接不同 Bucket
/// - 多签名支持：同时支持 OSS V1 和 V4 签名算法
/// - 请求管理：内置请求管理器,支持取消指定请求或所有请求
/// - 自动配置：根据提供的 [OSSConfig] 自动配置请求处理器和签名策略
/// - 模块化设计：通过 mixin 实现各个功能模块,便于维护和扩展
///
/// 使用流程：
/// 1. 创建 [OSSConfig] 配置对象
/// 2. 直接创建 [OSSClient] 实例
/// 3. 使用实例调用各种 OSS 操作方法
///
/// 示例：
/// ```dart
/// final config = OSSConfig(
///   accessKeyId: 'your-access-key-id',
///   accessKeySecret: 'your-access-key-secret',
///   endpoint: 'oss-cn-hangzhou.aliyuncs.com',
///   bucketName: 'your-bucket-name',
/// );
///
/// final client = OSSClient(config);
///
/// // 下载文件
/// final response = await client.getObject('example.txt');
///
/// // 上传文件
/// await client.putObject(File('local.txt'), 'remote.txt');
///
/// // 生成签名URL（默认使用V1签名）
/// final url = client.signedUrl('example.txt', expires: 3600);
///
/// // 生成V4签名URL
/// final urlV4 = client.signedUrl('example.txt', isV1Signature: false);
/// ```
class OSSClient
    with
        IOSSService,
        GetObjectImpl,
        PutObjectImpl,
        InitiateMultipartUploadImpl,
        UploadPartImpl,
        CompleteMultipartUploadImpl,
        AbortMultipartUploadImpl,
        ListPartsImpl,
        ListMultipartUploadsImpl,
        MultipartUploadImpl,
        SignedUrlImpl,
        DeleteObjectImpl,
        ListBucketResultImpl {
  //============================================================
  // 构造函数
  //============================================================

  factory OSSClient(
    OSSConfig config, {
    Duration connectTimeout = const Duration(seconds: 15),
    Duration receiveTimeout = const Duration(minutes: 5),
    Duration sendTimeout = const Duration(minutes: 10),
  }) {
    try {
      _validateConfig(config);
      final OSSRequestManager requestManager = OSSRequestManager();
      final Dio dio = _buildDio(
        config: config,
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
      );
      log(
        'OSSClient 初始化成功 - 端点: ${config.endpoint}, 存储空间: ${config.bucketName}, 区域: ${config.region}',
      );
      return OSSClient._internal(
        config: config,
        requestHandler: OSSRequestHandler(dio, requestManager),
        signStrategies: <bool, IOSSSignStrategy>{
          true: V1SignStrategy(config),
          false: AliOssV4SignStrategy(config),
        },
        requestManager: requestManager,
      );
    } catch (e) {
      log('OSSClient 初始化失败: $e', level: 1000);
      throw Exception('初始化 OSSClient 失败: $e');
    }
  }

  OSSClient._internal({
    required this.config,
    required this.requestHandler,
    required Map<bool, IOSSSignStrategy> signStrategies,
    required OSSRequestManager requestManager,
  }) : _signStrategies = signStrategies,
       _requestManager = requestManager;

  /// OSS 配置信息
  final OSSConfig config;

  /// 底层 HTTP 请求处理器
  final OSSRequestHandler requestHandler;

  /// 签名策略映射
  ///
  /// 存储不同类型的签名策略实现,使用布尔值作为键：
  /// - true: [AliOssV1SignStrategy] - V1签名算法（旧版,基于 HMAC-SHA1）
  /// - false: [AliOssV4SignStrategy] - V4签名算法（新版,基于 HMAC-SHA256,默认使用）
  ///
  /// 这种设计允许客户端根据需要切换不同的签名算法,同时保持向后兼容性。
  /// 对于新应用,建议使用 V4 签名算法（false键）。
  final Map<bool, IOSSSignStrategy> _signStrategies;

  /// 请求管理器,用于取消请求
  final OSSRequestManager _requestManager;

  /// 获取请求管理器实例
  ///
  /// 提供对请求管理器的访问,允许在客户端外部管理请求。
  /// 这对于需要在不同组件间共享请求管理功能的场景非常有用。
  ///
  /// 返回 [OSSRequestManager] 实例,可用于取消请求或监控请求状态。
  ///
  /// 示例：
  /// ```dart
  /// // 在某个组件中获取请求管理器
  /// final requestManager = ossClient.requestManager;
  ///
  /// // 使用请求管理器取消特定请求
  /// requestManager.cancelRequest('my-upload-task');
  /// ```
  OSSRequestManager get requestManager => _requestManager;

  static void _validateConfig(OSSConfig config) {
    if (config.accessKeyId.isEmpty) {
      throw ArgumentError('accessKeyId 不能为空');
    }
    if (config.accessKeySecret.isEmpty) {
      throw ArgumentError('accessKeySecret 不能为空');
    }
    if (config.endpoint.isEmpty) {
      throw ArgumentError('endpoint 不能为空');
    }
    if (config.bucketName.isEmpty) {
      throw ArgumentError('bucketName 不能为空');
    }
  }

  static Dio _buildDio({
    required OSSConfig config,
    required Duration connectTimeout,
    required Duration receiveTimeout,
    required Duration sendTimeout,
  }) {
    final Dio dio = config.dio ??
        Dio(
          BaseOptions(
            connectTimeout: connectTimeout,
            receiveTimeout: receiveTimeout,
            sendTimeout: sendTimeout,
          ),
        );

    if (config.enableLogInterceptor) {
      dio.interceptors.add(
        const OSSLogInterceptor(requestBody: true, responseBody: true),
      );
    }
    if (config.interceptors != null && config.interceptors!.isNotEmpty) {
      dio.interceptors.addAll(config.interceptors!);
    }

    return dio;
  }

  //============================================================
  // 公共接口实现 (IOSSService) 请查看各API 的 Impl 文件
  //============================================================

  //============================================================
  // 请求管理
  //============================================================

  /// 取消指定键的请求
  ///
  /// 根据提供的唯一标识取消正在进行的 OSS 请求。
  /// 这对于取消长时间运行的操作（如大文件上传或下载）非常有用。
  ///
  /// 参数：
  /// - [requestKey] 请求的唯一标识,可以是 fileKey 或其他唯一标识
  ///
  /// 示例：
  /// ```dart
  /// // 取消正在上传的文件
  /// client.cancelRequest('example.zip');
  /// ```
  void cancelRequest(String requestKey) {
    _requestManager.cancelRequest(requestKey);
  }

  /// 取消所有请求
  ///
  /// 取消当前所有正在进行的 OSS 请求。
  /// 这在需要快速释放资源或应用退出时非常有用。
  ///
  /// 示例：
  /// ```dart
  /// // 取消所有正在进行的请求
  /// client.cancelAll();
  /// ```
  void cancelAll() {
    _requestManager.cancelAll();
  }

  //============================================================
  // 辅助方法
  //============================================================

  /// 构建阿里云OSS的URI
  ///
  /// 根据提供的参数构建完整的OSS URI。
  ///
  /// 参数：
  /// - [bucket] OSS存储空间名称，如果不提供则使用配置中的默认值
  /// - [fileKey] OSS对象键（文件路径）
  /// - [queryParameters] 可选的查询参数，支持各种类型的值，非字符串类型会自动转换为字符串
  ///
  /// 返回构建好的URI对象
  ///
  /// 示例：
  /// ```dart
  /// final uri = buildOssUri(
  ///   fileKey: 'example.txt',
  ///   queryParameters: {'uploads': '', 'partNumber': 1},
  /// );
  /// // 结果: https://my-bucket.oss-cn-hangzhou.aliyuncs.com/example.txt?uploads=&partNumber=1
  /// ```
  Uri buildOssUri({
    String? bucket,
    required String fileKey,
    Map<String, dynamic>? queryParameters,
  }) {
    final String bucketName = bucket ?? config.bucketName;

    // 将所有查询参数转换为字符串
    Map<String, String>? stringQueryParams;
    if (queryParameters != null && queryParameters.isNotEmpty) {
      stringQueryParams = <String, String>{};
      queryParameters.forEach((String key, dynamic value) {
        if (value != null) {
          // 根据不同类型进行安全转换
          if (value is String) {
            stringQueryParams![key] = value;
          } else if (value is num || value is bool) {
            // 数字和布尔值可以安全地转换为字符串
            stringQueryParams![key] = value.toString();
          } else if (value is List || value is Map) {
            // 使用 jsonEncode 处理复杂类型
            try {
              stringQueryParams![key] = jsonEncode(value);
            } catch (e) {
              log('警告: 无法将复杂类型转换为JSON字符串: $e', level: 900);
              // 回退到 toString 方法
              stringQueryParams![key] = value.toString();
            }
          } else {
            // 其他类型使用 toString，但记录警告
            stringQueryParams![key] = value.toString();
            log('警告: 将未知类型 ${value.runtimeType} 转换为字符串', level: 500);
          }
        }
      });
    }

    // 根据是否启用CNAME选择不同的域名构造方式
    final String hostName = config.cname
        ? config.endpoint // 使用自定义域名
        : '$bucketName.${config.endpoint}'; // 使用标准OSS域名格式

    return Uri.https(
      hostName,
      fileKey,
      stringQueryParams,
    );
  }

  /// 创建带签名的请求头
  ///
  /// 根据提供的参数生成带有阿里云 OSS 认证签名的请求头。
  /// 支持 V1 和 V4 签名算法,通过 [isV1Signature] 参数切换。
  ///
  /// 签名算法对比：
  /// - V1签名（[isV1Signature]=true）：基于 HMAC-SHA1,生成的授权头格式为 `OSS {AccessKeyId}:{Signature}`
  /// - V4签名（[isV1Signature]=false）：基于 HMAC-SHA256,生成的授权头格式更复杂,包含区域信息和认证范围
  ///
  /// 内部实现过程：
  /// 1. 验证必要参数并准备标准化的头部
  /// 2. 构建请求URI
  /// 3. 根据 [isV1Signature] 参数从 [_signStrategies] 映射中获取相应的签名策略
  /// 4. 调用选定签名策略的 [signHeaders] 方法生成签名头
  ///
  /// 参数：
  /// - [bucketName] 存储空间名称,如果不提供则使用配置中的默认值
  /// - [method] HTTP 请求方法（GET、PUT、POST 等）
  /// - [fileKey] OSS 对象键（文件路径）
  /// - [queryParameters] 可选的查询参数
  /// - [contentLength] 请求体长度（如果有）
  /// - [baseHeaders] 基础请求头,将被扩展并签名
  /// - [dateTime] 用于签名的时间,如果不提供则使用当前时间
  /// - [isV1Signature] 是否使用 V1 签名算法,默认为 false（使用 V4 签名）
  /// - [params] 可选的请求参数，如果提供，将使用其中的 queryParameters
  ///
  /// 返回包含完整签名头部的 Map,可直接用于 HTTP 请求。
  ///
  /// 示例：
  /// ```dart
  /// final headers = client.createSignedHeaders(
  ///   method: 'GET',
  ///   fileKey: 'example.txt',
  ///   baseHeaders: {'Accept': 'application/octet-stream'},
  ///   isV1Signature: false, // 使用 V4 签名（默认）
  /// );
  /// ```
  Map<String, dynamic> createSignedHeaders({
    String? bucketName,
    required String method,
    required String fileKey,
    Map<String, dynamic>? queryParameters,
    int? contentLength,
    required Map<String, dynamic> baseHeaders,
    DateTime? dateTime,
    bool isV1Signature = false,
    OSSRequestParams? params,
  }) {
    // 验证必要参数
    if (fileKey.isEmpty) {
      throw ArgumentError('fileKey 不能为空');
    }
    if (method.isEmpty) {
      throw ArgumentError('method 不能为空');
    }

    // 准备参数
    final String bucket = bucketName ?? params?.bucketName ?? config.bucketName;
    final DateTime now = dateTime ?? params?.dateTime ?? DateTime.now().toUtc();
    final String date = HttpDate.format(now);

    // 合并查询参数
    Map<String, dynamic>? mergedQueryParams = queryParameters;
    if (params?.queryParameters != null) {
      mergedQueryParams = mergedQueryParams ?? <String, dynamic>{};
      mergedQueryParams.addAll(params!.queryParameters!);
    }

    // 构建URI
    final Uri uri = buildOssUri(
      bucket: bucket,
      fileKey: fileKey,
      queryParameters: mergedQueryParams,
    );

    // 尝试从 baseHeaders 获取 Content-Type
    // 注意：大小写不敏感的头部处理
    String? headerContentType;
    for (final MapEntry<String, dynamic> entry in baseHeaders.entries) {
      if (entry.key.toLowerCase() == 'content-type') {
        headerContentType = entry.value as String?;
        break;
      }
    }

    final String contentType = headerContentType ??
        // 对于 POST application/xml,不应依赖 lookupMimeType
        'application/octet-stream'; // 提供一个默认值

    // 构建标准化的头部 Map（全部小写键）
    final Map<String, dynamic> normalizedHeaders = <String, dynamic>{};
    baseHeaders.forEach((String key, dynamic value) {
      normalizedHeaders[key.toLowerCase()] = value;
    });

    // 确保必要的头部存在
    normalizedHeaders['content-type'] = contentType;
    if (contentLength != null) {
      normalizedHeaders['content-length'] = contentLength;
    }
    normalizedHeaders['x-oss-date'] = date;
    normalizedHeaders['date'] = date; // 有些场景可能需要 Date

    // 获取并验证签名策略
    final IOSSSignStrategy? signStrategy = _signStrategies[isV1Signature];
    if (signStrategy == null) {
      throw StateError('未找到${isV1Signature ? 'V1' : 'V4'}签名策略,请确保客户端已正确初始化');
    }

    // 调用签名策略
    return signStrategy.signHeaders(
      method: method,
      uri: uri,
      bucket: bucket,
      fileKey: fileKey,
      headers: normalizedHeaders,
      contentType: contentType,
      contentLength: contentLength,
      dateTime: now,
    );
  }
}
