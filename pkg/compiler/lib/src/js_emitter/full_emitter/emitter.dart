// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.js_emitter.full_emitter;

import 'dart:convert';

import 'package:js_runtime/shared/embedded_names.dart' as embeddedNames;
import 'package:js_runtime/shared/embedded_names.dart'
    show JsBuiltin, JsGetName;

import '../../../compiler_new.dart';
import '../../common.dart';
import '../../common_elements.dart' show CommonElements, ElementEnvironment;
import '../../compiler.dart' show Compiler;
import '../../constants/values.dart';
import '../../deferred_load.dart'
    show deferredPartFileName, OutputUnit, OutputUnitData;
import '../../elements/entities.dart';
import '../../hash/sha1.dart' show Hasher;
import '../../io/code_output.dart';
import '../../io/location_provider.dart' show LocationCollector;
import '../../io/source_map_builder.dart' show SourceMapBuilder;
import '../../js/js.dart' as jsAst;
import '../../js/js.dart' show js;
import '../../js_backend/js_backend.dart'
    show ConstantEmitter, JavaScriptBackend, Namer;
import '../../js_backend/native_data.dart';
import '../../js_backend/js_interop_analysis.dart' as jsInteropAnalysis;
import '../../universe/call_structure.dart' show CallStructure;
import '../../universe/codegen_world_builder.dart';
import '../../util/uri_extras.dart' show relativize;
import '../../world.dart' show JClosedWorld;
import '../constant_ordering.dart' show ConstantOrdering;
import '../headers.dart';
import '../js_emitter.dart' hide Emitter, EmitterFactory;
import '../js_emitter.dart' as js_emitter show EmitterBase, EmitterFactory;
import '../model.dart';
import '../program_builder/program_builder.dart';
import '../sorter.dart';

import 'class_builder.dart';
import 'class_emitter.dart';
import 'container_builder.dart';
import 'interceptor_emitter.dart';
import 'nsm_emitter.dart';

export 'class_builder.dart';
export 'class_emitter.dart';
export 'container_builder.dart';
export 'interceptor_emitter.dart';
export 'nsm_emitter.dart';

part 'code_emitter_helper.dart';
part 'declarations.dart';
part 'deferred_output_unit_hash.dart';
part 'setup_program_builder.dart';

class EmitterFactory implements js_emitter.EmitterFactory {
  final bool generateSourceMap;

  EmitterFactory({this.generateSourceMap});

  @override
  bool get supportsReflection => true;

  @override
  Emitter createEmitter(CodeEmitterTask task, Namer namer,
      JClosedWorld closedWorld, Sorter sorter) {
    return new Emitter(
        task.compiler, namer, closedWorld, generateSourceMap, task, sorter);
  }
}

class Emitter extends js_emitter.EmitterBase {
  final Compiler compiler;
  final CodeEmitterTask task;
  final JClosedWorld _closedWorld;

  // The following fields will be set to copies of the program-builder's
  // collector.
  Map<OutputUnit, List<FieldEntity>> outputStaticNonFinalFieldLists;
  Map<OutputUnit, Set<LibraryEntity>> outputLibraryLists;

  final ContainerBuilder containerBuilder;
  final ClassEmitter classEmitter;
  final NsmEmitter nsmEmitter;
  final InterceptorEmitter interceptorEmitter;
  final Sorter _sorter;
  final ConstantOrdering _constantOrdering;

  // TODO(johnniwinther): Wrap these fields in a caching strategy.
  final List<jsAst.Statement> cachedEmittedConstantsAst = <jsAst.Statement>[];

  bool needsClassSupport = false;
  bool needsMixinSupport = false;
  bool needsLazyInitializer = false;

  /// True if [ContainerBuilder.addMemberMethodFromInfo] used "structured info",
  /// that is, some function was needed for reflection, had stubs, or had a
  /// super alias.
  bool needsStructuredMemberInfo = false;

  final Namer namer;
  ConstantEmitter constantEmitter;
  NativeEmitter get nativeEmitter => task.nativeEmitter;
  TypeTestRegistry get typeTestRegistry => task.typeTestRegistry;
  CommonElements get commonElements => _closedWorld.commonElements;
  ElementEnvironment get _elementEnvironment => _closedWorld.elementEnvironment;
  CodegenWorldBuilder get _worldBuilder => compiler.codegenWorldBuilder;
  OutputUnitData get _outputUnitData => _closedWorld.outputUnitData;

  // The full code that is written to each hunk part-file.
  Map<OutputUnit, CodeOutput> outputBuffers = new Map<OutputUnit, CodeOutput>();

  String classesCollector;

  JavaScriptBackend get backend => compiler.backend;

  String get _ => space;
  String get space => compiler.options.enableMinification ? "" : " ";
  String get n => compiler.options.enableMinification ? "" : "\n";
  String get N => compiler.options.enableMinification ? "\n" : ";\n";

  /**
   * List of expressions and statements that will be included in the
   * precompiled function.
   *
   * To save space, dart2js normally generates constructors and accessors
   * dynamically. This doesn't work in CSP mode, so dart2js emits them directly
   * when in CSP mode.
   */
  Map<OutputUnit, List<jsAst.Node>> _cspPrecompiledFunctions =
      new Map<OutputUnit, List<jsAst.Node>>();

  Map<OutputUnit, List<jsAst.Expression>> _cspPrecompiledConstructorNames =
      new Map<OutputUnit, List<jsAst.Expression>>();

  /**
   * Accumulate properties for classes and libraries, describing their
   * static/top-level members.
   * Later, these members are emitted when the class or library is emitted.
   *
   * See [getElementDescriptor].
   */
  // TODO(ahe): Generate statics with their class, and store only libraries in
  // this map.
  final Map<Fragment, Map<LibraryEntity, ClassBuilder>> libraryDescriptors =
      new Map<Fragment, Map<LibraryEntity, ClassBuilder>>();

  final Map<Fragment, Map<ClassEntity, ClassBuilder>> classDescriptors =
      new Map<Fragment, Map<ClassEntity, ClassBuilder>>();

  final bool generateSourceMap;

  Emitter(this.compiler, this.namer, this._closedWorld, this.generateSourceMap,
      this.task, Sorter sorter)
      : classEmitter = new ClassEmitter(_closedWorld),
        interceptorEmitter = new InterceptorEmitter(_closedWorld),
        nsmEmitter = new NsmEmitter(_closedWorld),
        _sorter = sorter,
        containerBuilder = new ContainerBuilder(_closedWorld),
        _constantOrdering = new ConstantOrdering(sorter) {
    constantEmitter = new ConstantEmitter(
        compiler.options,
        _closedWorld.commonElements,
        compiler.codegenWorldBuilder,
        _closedWorld.rtiNeed,
        compiler.backend.rtiEncoder,
        _closedWorld.allocatorAnalysis,
        task,
        this.constantReference,
        constantListGenerator);
    containerBuilder.emitter = this;
    classEmitter.emitter = this;
    nsmEmitter.emitter = this;
    interceptorEmitter.emitter = this;
  }

  DiagnosticReporter get reporter => compiler.reporter;

  NativeData get _nativeData => _closedWorld.nativeData;

  List<jsAst.Node> cspPrecompiledFunctionFor(OutputUnit outputUnit) {
    return _cspPrecompiledFunctions.putIfAbsent(
        outputUnit, () => new List<jsAst.Node>());
  }

  List<jsAst.Expression> cspPrecompiledConstructorNamesFor(
      OutputUnit outputUnit) {
    return _cspPrecompiledConstructorNames.putIfAbsent(
        outputUnit, () => new List<jsAst.Expression>());
  }

  @override
  bool isConstantInlinedOrAlreadyEmitted(ConstantValue constant) {
    if (constant.isFunction) return true; // Already emitted.
    if (constant.isPrimitive) return true; // Inlined.
    if (constant.isDummy) return true; // Inlined.
    // The name is null when the constant is already a JS constant.
    // TODO(floitsch): every constant should be registered, so that we can
    // share the ones that take up too much space (like some strings).
    if (namer.constantName(constant) == null) return true;
    return false;
  }

  @override
  int compareConstants(ConstantValue a, ConstantValue b) {
    // Inlined constants don't affect the order and sometimes don't even have
    // names.
    int cmp1 = isConstantInlinedOrAlreadyEmitted(a) ? 0 : 1;
    int cmp2 = isConstantInlinedOrAlreadyEmitted(b) ? 0 : 1;
    if (cmp1 + cmp2 < 2) return cmp1 - cmp2;

    // Emit constant interceptors first. Constant interceptors for primitives
    // might be used by code that builds other constants.  See Issue 18173.
    if (a.isInterceptor != b.isInterceptor) {
      return a.isInterceptor ? -1 : 1;
    }

    // Sorting by the long name clusters constants with the same constructor
    // which compresses a tiny bit better.
    int r = namer.constantLongName(a).compareTo(namer.constantLongName(b));
    if (r != 0) return r;

    // Resolve collisions in the long name by using a structural order.
    return _constantOrdering.compare(a, b);
  }

  @override
  jsAst.Expression constantReference(ConstantValue value) {
    if (value.isFunction) {
      FunctionConstantValue functionConstant = value;
      return isolateStaticClosureAccess(functionConstant.element);
    }

    // We are only interested in the "isInlined" part, but it does not hurt to
    // test for the other predicates.
    if (isConstantInlinedOrAlreadyEmitted(value)) {
      return constantEmitter.generate(value);
    }
    return js('#.#',
        [namer.globalObjectForConstant(value), namer.constantName(value)]);
  }

  jsAst.Expression constantInitializerExpression(ConstantValue value) {
    return constantEmitter.generate(value);
  }

  String get name => 'CodeEmitter';

  String get finishIsolateConstructorName =>
      '${namer.isolateName}.\$finishIsolateConstructor';
  String get isolatePropertiesName =>
      '${namer.isolateName}.${namer.isolatePropertiesName}';
  String get lazyInitializerProperty => r'$lazy';
  String get lazyInitializerName =>
      '${namer.isolateName}.${lazyInitializerProperty}';
  String get initName => 'init';

  jsAst.Name get makeConstListProperty =>
      namer.internalGlobal('makeConstantList');

  /// For deferred loading we communicate the initializers via this global var.
  final String deferredInitializers = r"$dart_deferred_initializers$";

  /// Contains the global state that is needed to initialize and load a
  /// deferred library.
  String get globalsHolder => r"$globals$";

  @override
  jsAst.Expression generateEmbeddedGlobalAccess(String global) {
    return js(generateEmbeddedGlobalAccessString(global));
  }

  String generateEmbeddedGlobalAccessString(String global) {
    // TODO(floitsch): don't use 'init' as global embedder storage.
    return '$initName.$global';
  }

  @override
  jsAst.Expression isolateLazyInitializerAccess(FieldEntity element) {
    return jsAst.js('#.#', [
      namer.globalObjectForMember(element),
      namer.lazyInitializerName(element)
    ]);
  }

  @override
  jsAst.Expression isolateStaticClosureAccess(FunctionEntity element) {
    return jsAst.js('#.#()', [
      namer.globalObjectForMember(element),
      namer.staticClosureName(element)
    ]);
  }

  @override
  jsAst.PropertyAccess prototypeAccess(
      ClassEntity element, bool hasBeenInstantiated) {
    return jsAst.js('#.prototype', constructorAccess(element));
  }

  @override
  jsAst.Template templateForBuiltin(JsBuiltin builtin) {
    switch (builtin) {
      case JsBuiltin.dartObjectConstructor:
        return jsAst.js
            .expressionTemplateYielding(typeAccess(commonElements.objectClass));

      case JsBuiltin.isCheckPropertyToJsConstructorName:
        int isPrefixLength = namer.operatorIsPrefix.length;
        return jsAst.js.expressionTemplateFor('#.substring($isPrefixLength)');

      case JsBuiltin.isFunctionType:
        return backend.rtiEncoder.templateForIsFunctionType;

      case JsBuiltin.isFutureOrType:
        return backend.rtiEncoder.templateForIsFutureOrType;

      case JsBuiltin.isVoidType:
        return backend.rtiEncoder.templateForIsVoidType;

      case JsBuiltin.isDynamicType:
        return backend.rtiEncoder.templateForIsDynamicType;

      case JsBuiltin.isJsInteropTypeArgument:
        return backend.rtiEncoder.templateForIsJsInteropTypeArgument;

      case JsBuiltin.rawRtiToJsConstructorName:
        return jsAst.js.expressionTemplateFor("#.$typeNameProperty");

      case JsBuiltin.rawRuntimeType:
        return jsAst.js.expressionTemplateFor("#.constructor");

      case JsBuiltin.isSubtype:
        // TODO(floitsch): move this closer to where is-check properties are
        // built.
        String isPrefix = namer.operatorIsPrefix;
        return jsAst.js
            .expressionTemplateFor("('$isPrefix' + #) in #.prototype");

      case JsBuiltin.isGivenTypeRti:
        return jsAst.js.expressionTemplateFor('#.$typeNameProperty === #');

      case JsBuiltin.getMetadata:
        String metadataAccess =
            generateEmbeddedGlobalAccessString(embeddedNames.METADATA);
        return jsAst.js.expressionTemplateFor("$metadataAccess[#]");

      case JsBuiltin.getType:
        String typesAccess =
            generateEmbeddedGlobalAccessString(embeddedNames.TYPES);
        return jsAst.js.expressionTemplateFor("$typesAccess[#]");

      default:
        reporter.internalError(
            NO_LOCATION_SPANNABLE, "Unhandled Builtin: $builtin");
        return null;
    }
  }

  @override
  int generatedSize(OutputUnit unit) {
    return outputBuffers[unit].length;
  }

  List<jsAst.Statement> buildTrivialNsmHandlers() {
    return nsmEmitter.buildTrivialNsmHandlers();
  }

  jsAst.Statement buildNativeInfoHandler(
      jsAst.Expression infoAccess,
      jsAst.Expression constructorAccess,
      jsAst.Expression subclassReadGenerator(jsAst.Expression subclass),
      jsAst.Expression interceptorsByTagAccess,
      jsAst.Expression leafTagsAccess) {
    return NativeGenerator.buildNativeInfoHandler(infoAccess, constructorAccess,
        subclassReadGenerator, interceptorsByTagAccess, leafTagsAccess);
  }

  /// In minified mode we want to keep the name for the most common core types.
  bool _isNativeTypeNeedingReflectionName(ClassEntity element) {
    return (element == commonElements.intClass ||
        element == commonElements.doubleClass ||
        element == commonElements.numClass ||
        element == commonElements.stringClass ||
        element == commonElements.boolClass ||
        element == commonElements.nullClass ||
        element == commonElements.listClass);
  }

  /// Returns the "reflection name" of a [ClassEntity], if needed.
  ///
  /// The reflection name of class 'C' is 'C'.
  /// An anonymous mixin application has no reflection name.
  ///
  /// This is used by js_mirrors.dart.
  // TODO(johnniwinther): Do we still need this when js_mirrors is deleted?
  String getReflectionClassName(ClassEntity cls, jsAst.Name mangledName) {
    // Make sure to retain names of common native types.
    if (_isNativeTypeNeedingReflectionName(cls)) {
      assert(!cls.isClosure);
      assert(!_elementEnvironment.isUnnamedMixinApplication(cls));
      return cls.name;
    }
    return null;
  }

  String namedParametersAsReflectionNames(CallStructure structure) {
    if (structure.isUnnamed) return '';
    String names = structure.getOrderedNamedArguments().join(':');
    return ':$names';
  }

  jsAst.Statement buildCspPrecompiledFunctionFor(OutputUnit outputUnit) {
    if (compiler.options.useContentSecurityPolicy) {
      // TODO(ahe): Compute a hash code.
      // TODO(sigurdm): Avoid this precompiled function. Generated
      // constructor-functions and getter/setter functions can be stored in the
      // library-description table. Setting properties on these can be moved to
      // finishClasses.
      return js.statement(r"""
        #precompiled = function ($collectedClasses$) {
          #norename;
          var $desc;
          #functions;
          return #result;
        };""", {
        'norename': new jsAst.Comment("// ::norenaming:: "),
        'precompiled': generateEmbeddedGlobalAccess(embeddedNames.PRECOMPILED),
        'functions': cspPrecompiledFunctionFor(outputUnit),
        'result': new jsAst.ArrayInitializer(
            cspPrecompiledConstructorNamesFor(outputUnit))
      });
    } else {
      return js.comment("Constructors are generated at runtime.");
    }
  }

  void assembleClass(
      Class cls, ClassBuilder enclosingBuilder, Fragment fragment) {
    ClassEntity classElement = cls.element;
    reporter.withCurrentElement(classElement, () {
      classEmitter.emitClass(cls, enclosingBuilder, fragment);
    });
  }

  void assembleStaticFunctions(
      Iterable<Method> staticFunctions, Fragment fragment) {
    if (staticFunctions == null) return;

    for (Method method in staticFunctions) {
      FunctionEntity element = method.element;
      // We need to filter out null-elements for the interceptors.
      // TODO(floitsch): use the precomputed interceptors here.
      if (element == null) continue;
      ClassBuilder builder = new ClassBuilder.forStatics(element, namer);
      containerBuilder.addMemberMethod(method, builder);
      getStaticMethodDescriptor(element, fragment)
          .properties
          .addAll(builder.properties);
    }
  }

  jsAst.Statement buildStaticNonFinalFieldInitializations(
      OutputUnit outputUnit) {
    jsAst.Statement buildInitialization(
        FieldEntity element, jsAst.Expression initialValue) {
      return js.statement('${namer.staticStateHolder}.# = #',
          [namer.globalPropertyNameForMember(element), initialValue]);
    }

    bool inMainUnit = (outputUnit == _outputUnitData.mainOutputUnit);
    List<jsAst.Statement> parts = <jsAst.Statement>[];

    Iterable<FieldEntity> fields = outputStaticNonFinalFieldLists[outputUnit];
    // If the outputUnit does not contain any static non-final fields, then
    // [fields] is `null`.
    if (fields != null) {
      for (FieldEntity element in fields) {
        reporter.withCurrentElement(element, () {
          ConstantValue constant =
              _worldBuilder.getConstantFieldInitializer(element);
          parts.add(buildInitialization(element, constantReference(constant)));
        });
      }
    }

    if (inMainUnit && outputStaticNonFinalFieldLists.length > 1) {
      // In the main output-unit we output a stub initializer for deferred
      // variables, so that `isolateProperties` stays a fast object.
      outputStaticNonFinalFieldLists
          .forEach((OutputUnit fieldsOutputUnit, Iterable<FieldEntity> fields) {
        if (fieldsOutputUnit == outputUnit) return; // Skip the main unit.
        for (FieldEntity element in fields) {
          reporter.withCurrentElement(element, () {
            parts.add(buildInitialization(element, jsAst.number(0)));
          });
        }
      });
    }

    return new jsAst.Block(parts);
  }

  jsAst.Statement buildLazilyInitializedStaticFields(
      Iterable<StaticField> lazyFields,
      {bool isMainFragment: true}) {
    if (lazyFields.isNotEmpty) {
      needsLazyInitializer = true;
      List<jsAst.Expression> laziesInfo =
          buildLaziesInfo(lazyFields, isMainFragment);
      return js.statement('''
      (function(lazies) {
        for (var i = 0; i < lazies.length; ) {
          var fieldName = lazies[i++];
          var getterName = lazies[i++];
          var lazyValue = lazies[i++];
          if (#notMinified) {
            var staticName = lazies[i++];
          }
          if (#isDeferredFragment) {
            var fieldHolder = lazies[i++];
          }
          // We build the lazy-check here:
          //   lazyInitializer(fieldName, getterName, lazyValue, staticName);
          // 'staticName' is used for error reporting in non-minified mode.
          // 'lazyValue' must be a closure that constructs the initial value.
          if (#isMainFragment) {
            if (#notMinified) {
              #lazy(fieldName, getterName, lazyValue, staticName);
            } else {
              #lazy(fieldName, getterName, lazyValue);
            }
          } else {
            if (#notMinified) {
              #lazy(fieldName, getterName, lazyValue, staticName, fieldHolder);
            } else {
              #lazy(fieldName, getterName, lazyValue, null, fieldHolder);
            }
          }
        }
      })(#laziesInfo)
      ''', {
        'notMinified': !compiler.options.enableMinification,
        'laziesInfo': new jsAst.ArrayInitializer(laziesInfo),
        'lazy': js(lazyInitializerName),
        'isMainFragment': isMainFragment,
        'isDeferredFragment': !isMainFragment
      });
    } else {
      return js.comment("No lazy statics.");
    }
  }

  List<jsAst.Expression> buildLaziesInfo(
      Iterable<StaticField> lazies, bool isMainFragment) {
    List<jsAst.Expression> laziesInfo = <jsAst.Expression>[];
    for (StaticField field in lazies) {
      laziesInfo.add(js.quoteName(field.name));
      laziesInfo.add(js.quoteName(namer.deriveLazyInitializerName(field.name)));
      laziesInfo.add(field.code);
      if (!compiler.options.enableMinification) {
        laziesInfo.add(js.quoteName(field.name));
      }
      if (!isMainFragment) {
        laziesInfo.add(js('#', field.holder.name));
      }
    }
    return laziesInfo;
  }

  jsAst.Statement buildMetadata(Program program, OutputUnit outputUnit) {
    List<jsAst.Statement> parts = <jsAst.Statement>[];

    jsAst.Expression metadata = program.metadataForOutputUnit(outputUnit);
    jsAst.Expression types = program.metadataTypesForOutputUnit(outputUnit);

    if (outputUnit == _outputUnitData.mainOutputUnit) {
      jsAst.Expression metadataAccess =
          generateEmbeddedGlobalAccess(embeddedNames.METADATA);
      jsAst.Expression typesAccess =
          generateEmbeddedGlobalAccess(embeddedNames.TYPES);

      parts
        ..add(js.statement('# = #;', [metadataAccess, metadata]))
        ..add(js.statement('# = #;', [typesAccess, types]));
    } else if (types != null) {
      parts.add(
          js.statement('var ${namer.deferredMetadataName} = #;', metadata));
      parts.add(js.statement('var ${namer.deferredTypesName} = #;', types));
    }
    return new jsAst.Block(parts);
  }

  jsAst.Statement buildCompileTimeConstants(List<Constant> constants,
      {bool isMainFragment}) {
    assert(isMainFragment != null);

    if (constants.isEmpty) return js.comment("No constants in program.");
    List<jsAst.Statement> parts = <jsAst.Statement>[];
    for (Constant constant in constants) {
      ConstantValue constantValue = constant.value;
      parts.add(buildConstantInitializer(constantValue));
    }

    return new jsAst.Block(parts);
  }

  jsAst.Statement buildConstantInitializer(ConstantValue constant) {
    jsAst.Name name = namer.constantName(constant);
    jsAst.Statement initializer = js.statement('#.# = #', [
      namer.globalObjectForConstant(constant),
      name,
      constantInitializerExpression(constant)
    ]);
    compiler.dumpInfoTask.registerConstantAst(constant, initializer);
    return initializer;
  }

  jsAst.Expression constantListGenerator(jsAst.Expression array) {
    // TODO(floitsch): there is no harm in caching the template.
    return js('${namer.isolateName}.#(#)', [makeConstListProperty, array]);
  }

  jsAst.Statement buildMakeConstantList(bool outputContainsConstantList) {
    if (outputContainsConstantList) {
      return js.statement(r'''
          // Functions are stored in the hidden class and not as properties in
          // the object. We never actually look at the value, but only want
          // to know if the property exists.
          #.# = function (list) {
            list.immutable$list = Array;
            list.fixed$length = Array;
            return list;
          }''', [namer.isolateName, makeConstListProperty]);
    } else {
      return js.comment("Output contains no constant list.");
    }
  }

  jsAst.Statement buildFunctionThatReturnsNull() {
    return js.statement('#.# = function() {}',
        [namer.isolateName, backend.rtiEncoder.getFunctionThatReturnsNullName]);
  }

  jsAst.Expression generateFunctionThatReturnsNull() {
    return js("#.#",
        [namer.isolateName, backend.rtiEncoder.getFunctionThatReturnsNullName]);
  }

  buildMain(jsAst.Statement invokeMain) {
    List<jsAst.Statement> parts = <jsAst.Statement>[];

    if (NativeGenerator.needsIsolateAffinityTagInitialization(
        _closedWorld.backendUsage)) {
      parts.add(NativeGenerator.generateIsolateAffinityTagInitialization(
          _closedWorld.backendUsage, generateEmbeddedGlobalAccess, js("""
        // On V8, the 'intern' function converts a string to a symbol, which
        // makes property access much faster.
        function (s) {
          var o = {};
          o[s] = 1;
          return Object.keys(convertToFastObject(o))[0];
        }""", [])));
    }

    parts
      ..add(js.comment('BEGIN invoke [main].'))
      ..add(invokeMain)
      ..add(js.comment('END invoke [main].'));

    return new jsAst.Block(parts);
  }

  jsAst.Statement buildInitFunction(bool outputContainsConstantList) {
    jsAst.Expression allClassesAccess =
        generateEmbeddedGlobalAccess(embeddedNames.ALL_CLASSES);
    jsAst.Expression getTypeFromNameAccess =
        generateEmbeddedGlobalAccess(embeddedNames.GET_TYPE_FROM_NAME);
    jsAst.Expression interceptorsByTagAccess =
        generateEmbeddedGlobalAccess(embeddedNames.INTERCEPTORS_BY_TAG);
    jsAst.Expression leafTagsAccess =
        generateEmbeddedGlobalAccess(embeddedNames.LEAF_TAGS);
    jsAst.Expression finishedClassesAccess =
        generateEmbeddedGlobalAccess(embeddedNames.FINISHED_CLASSES);
    jsAst.Expression cyclicThrow =
        staticFunctionAccess(commonElements.cyclicThrowHelper);
    jsAst.Expression laziesAccess =
        generateEmbeddedGlobalAccess(embeddedNames.LAZIES);

    return js.statement("""
      function init() {
        $isolatePropertiesName = Object.create(null);
        #allClasses = map();
        #getTypeFromName = function(name) {return #allClasses[name];};
        #interceptorsByTag = map();
        #leafTags = map();
        #finishedClasses = map();

        if (#needsLazyInitializer) {
          // [staticName] is only provided in non-minified mode. If missing, we
          // fall back to [fieldName]. Likewise, [prototype] is optional and
          // defaults to the isolateProperties object.
          $lazyInitializerName = function (fieldName, getterName, lazyValue,
                                           staticName, prototype) {
            if (!#lazies) #lazies = Object.create(null);
            #lazies[fieldName] = getterName;

            // 'prototype' will be undefined except if we are doing an update
            // during incremental compilation. In this case we put the lazy
            // field directly on the isolate instead of the isolateProperties.
            prototype = prototype || $isolatePropertiesName;
            var sentinelUndefined = {};
            var sentinelInProgress = {};
            prototype[fieldName] = sentinelUndefined;

            prototype[getterName] = function () {
              var result = this[fieldName];
              if (result == sentinelInProgress) {
                // In minified mode, static name is not provided, so fall back
                // to the minified fieldName.
                #cyclicThrow(staticName || fieldName);
              }
              try {
                if (result === sentinelUndefined) {
                  this[fieldName] = sentinelInProgress;
                  try {
                    result = this[fieldName] = lazyValue();
                  } finally {
                    // Use try-finally, not try-catch/throw as it destroys the
                    // stack trace.
                    if (result === sentinelUndefined)
                      this[fieldName] = null;
                  }
                }
                return result;
              } finally {
                this[getterName] = function() { return this[fieldName]; };
              }
            }
          }
        }

        // We replace the old Isolate function with a new one that initializes
        // all its fields with the initial (and often final) value of all
        // globals.
        //
        // We also copy over old values like the prototype, and the
        // isolateProperties themselves.
        $finishIsolateConstructorName = function (oldIsolate) {
          var isolateProperties = oldIsolate.#isolatePropertiesName;
          function Isolate() {

            var staticNames = Object.keys(isolateProperties);
            for (var i = 0; i < staticNames.length; i++) {
              var staticName = staticNames[i];
              this[staticName] = isolateProperties[staticName];
            }

            // Reset lazy initializers to null.
            // When forcing the object to fast mode (below) v8 will consider
            // functions as part the object's map. Since we will change them
            // (after the first call to the getter), we would have a map
            // transition.
            var lazies = init.lazies;
            var lazyInitializers = lazies ? Object.keys(lazies) : [];
            for (var i = 0; i < lazyInitializers.length; i++) {
               this[lazies[lazyInitializers[i]]] = null;
            }

            // Use the newly created object as prototype. In Chrome,
            // this creates a hidden class for the object and makes
            // sure it is fast to access.
            function ForceEfficientMap() {}
            ForceEfficientMap.prototype = this;
            new ForceEfficientMap();

            // Now, after being a fast map we can set the lazies again.
            for (var i = 0; i < lazyInitializers.length; i++) {
              var lazyInitName = lazies[lazyInitializers[i]];
              this[lazyInitName] = isolateProperties[lazyInitName];
            }
          }
          Isolate.prototype = oldIsolate.prototype;
          Isolate.prototype.constructor = Isolate;
          Isolate.#isolatePropertiesName = isolateProperties;
          if (#outputContainsConstantList) {
            Isolate.#makeConstListProperty = oldIsolate.#makeConstListProperty;
          }
          Isolate.#functionThatReturnsNullProperty =
              oldIsolate.#functionThatReturnsNullProperty;
          return Isolate;
      }

      }""", {
      'allClasses': allClassesAccess,
      'getTypeFromName': getTypeFromNameAccess,
      'interceptorsByTag': interceptorsByTagAccess,
      'leafTags': leafTagsAccess,
      'finishedClasses': finishedClassesAccess,
      'needsLazyInitializer': needsLazyInitializer,
      'lazies': laziesAccess,
      'cyclicThrow': cyclicThrow,
      'isolatePropertiesName': namer.isolatePropertiesName,
      'outputContainsConstantList': outputContainsConstantList,
      'makeConstListProperty': makeConstListProperty,
      'functionThatReturnsNullProperty':
          backend.rtiEncoder.getFunctionThatReturnsNullName,
    });
  }

  jsAst.Statement buildConvertToFastObjectFunction() {
    List<jsAst.Statement> debugCode = <jsAst.Statement>[];
    if (DEBUG_FAST_OBJECTS) {
      debugCode.add(js.statement(r'''
        // The following only works on V8 when run with option
        // "--allow-natives-syntax".  We use'new Function' because the
         // miniparser does not understand V8 native syntax.
        if (typeof print === "function") {
          var HasFastProperties =
            new Function("a", "return %HasFastProperties(a)");
          print("Size of global object: "
                   + String(Object.getOwnPropertyNames(properties).length)
                   + ", fast properties " + HasFastProperties(properties));
        }'''));
    }

    return js.statement(r'''
      function convertToFastObject(properties) {
        // Create an instance that uses 'properties' as prototype. This should
        // make 'properties' a fast object.
        function MyClass() {};
        MyClass.prototype = properties;
        new MyClass();
        #;
        return properties;
      }''', [debugCode]);
  }

  jsAst.Statement buildConvertToSlowObjectFunction() {
    return js.statement(r'''
    function convertToSlowObject(properties) {
      // Add and remove a property to make the object transition into hashmap
      // mode.
      properties.__MAGIC_SLOW_PROPERTY = 1;
      delete properties.__MAGIC_SLOW_PROPERTY;
      return properties;
    }''');
  }

  jsAst.Statement buildSupportsDirectProtoAccess() {
    jsAst.Statement supportsDirectProtoAccess;

    supportsDirectProtoAccess = js.statement(r'''
      var supportsDirectProtoAccess = (function () {
        var cls = function () {};
        cls.prototype = {'p': {}};
        var object = new cls();
        if (!(object.__proto__ && object.__proto__.p === cls.prototype.p))
          return false;

        try {
          // Are we running on a platform where the performance is good?
          // (i.e. Chrome or d8).

          // Chrome userAgent?
          if (typeof navigator != "undefined" &&
              typeof navigator.userAgent == "string" &&
              navigator.userAgent.indexOf("Chrome/") >= 0) return true;

          // d8 version() looks like "N.N.N.N", jsshell version() like "N".
          if (typeof version == "function" &&
              version.length == 0) {
            var v = version();
            if (/^\d+\.\d+\.\d+\.\d+$/.test(v)) return true;
          }
        } catch(_) {}

        return false;
      })();
    ''');

    return supportsDirectProtoAccess;
  }

  jsAst.Expression generateLibraryDescriptor(
      LibraryEntity library, Fragment fragment) {
    dynamic uri = "";
    if (!compiler.options.enableMinification) {
      uri = library.canonicalUri;
      if (uri.scheme == 'file' && compiler.options.outputUri != null) {
        uri =
            relativize(compiler.options.outputUri, library.canonicalUri, false);
      }
    }

    String libraryName = !compiler.options.enableMinification
        ? _elementEnvironment.getLibraryName(library)
        : "";

    jsAst.Fun metadata = null;

    ClassBuilder descriptor = libraryDescriptors[fragment][library];

    jsAst.ObjectInitializer initializer;
    if (descriptor == null) {
      // Nothing of the library was emitted.
      // TODO(floitsch): this should not happen. We currently have an example
      // with language/prefix6_negative_test.dart where we have an instance
      // method without its corresponding class.
      initializer = new jsAst.ObjectInitializer([]);
    } else {
      initializer = descriptor.toObjectInitializer();
    }

    compiler.dumpInfoTask.registerEntityAst(library, metadata);
    compiler.dumpInfoTask.registerEntityAst(library, initializer);

    List<jsAst.Expression> parts = <jsAst.Expression>[];
    parts
      ..add(js.string(libraryName))
      ..add(js.string(uri.toString()))
      ..add(metadata == null ? new jsAst.ArrayHole() : metadata)
      ..add(js('#', namer.globalObjectForLibrary(library)))
      ..add(initializer);
    if (library == _closedWorld.elementEnvironment.mainLibrary) {
      parts.add(js.number(1));
    }

    return new jsAst.ArrayInitializer(parts);
  }

  void assemblePrecompiledConstructor(
      OutputUnit outputUnit,
      jsAst.Name constructorName,
      jsAst.Expression constructorAst,
      List<jsAst.Name> fields) {
    cspPrecompiledFunctionFor(outputUnit)
        .add(new jsAst.FunctionDeclaration(constructorName, constructorAst));

    cspPrecompiledFunctionFor(outputUnit).add(js.statement(r'''
        {
          #constructorName.#typeNameProperty = #constructorNameString;
          // IE does not have a name property.
          if (!("name" in #constructorName))
              #constructorName.name = #constructorNameString;
          $desc = $collectedClasses$.#constructorName[1];
          #constructorName.prototype = $desc;
        }''', {
      "constructorName": constructorName,
      "typeNameProperty": typeNameProperty,
      "constructorNameString": js.quoteName(constructorName),
    }));

    cspPrecompiledConstructorNamesFor(outputUnit).add(js('#', constructorName));
  }

  jsAst.Statement buildGlobalObjectSetup(bool isProgramSplit) {
    List<jsAst.Statement> parts = <jsAst.Statement>[];

    parts.add(js.comment("""
      // The global objects start as so-called "slow objects". For V8, this
      // means that it won't try to make map transitions as we add properties
      // to these objects. Later on, we attempt to turn these objects into
      // fast objects by calling "convertToFastObject" (see
      // [emitConvertToFastObjectFunction]).
      """));

    for (String globalObject in Namer.reservedGlobalObjectNames) {
      if (isProgramSplit) {
        String template =
            "var #globalObject = #globalsHolder.#globalObject = map();";
        parts.add(js.statement(template,
            {"globalObject": globalObject, "globalsHolder": globalsHolder}));
      } else {
        parts.add(js.statement(
            "var #globalObject = map();", {"globalObject": globalObject}));
      }
    }

    return new jsAst.Block(parts);
  }

  jsAst.Statement buildConvertGlobalObjectToFastObjects() {
    List<jsAst.Statement> parts = <jsAst.Statement>[];

    for (String globalObject in Namer.reservedGlobalObjectNames) {
      parts.add(js.statement(
          '#globalObject = convertToFastObject(#globalObject);',
          {"globalObject": globalObject}));
    }

    return new jsAst.Block(parts);
  }

  jsAst.Statement buildDebugFastObjectCode() {
    List<jsAst.Statement> parts = <jsAst.Statement>[];

    if (DEBUG_FAST_OBJECTS) {
      parts.add(js.statement(r'''
          // The following only works on V8 when run with option
          // "--allow-natives-syntax".  We use'new Function' because the
          // miniparser does not understand V8 native syntax.
          if (typeof print === "function") {
            var HasFastProperties =
              new Function("a", "return %HasFastProperties(a)");
            print("Size of global helper object: "
                   + String(Object.getOwnPropertyNames(H).length)
                   + ", fast properties " + HasFastProperties(H));
            print("Size of global platform object: "
                   + String(Object.getOwnPropertyNames(P).length)
                   + ", fast properties " + HasFastProperties(P));
            print("Size of global dart:html object: "
                   + String(Object.getOwnPropertyNames(W).length)
                   + ", fast properties " + HasFastProperties(W));
            print("Size of isolate properties object: "
                   + String(Object.getOwnPropertyNames($).length)
                   + ", fast properties " + HasFastProperties($));
            print("Size of constant object: "
                   + String(Object.getOwnPropertyNames(C).length)
                   + ", fast properties " + HasFastProperties(C));
            var names = Object.getOwnPropertyNames($);
            for (var i = 0; i < names.length; i++) {
              print("$." + names[i]);
            }
          }
       '''));

      for (String object in Namer.userGlobalObjects) {
        parts.add(js.statement('''
          if (typeof print === "function") {
            print("Size of " + #objectString + ": "
                  + String(Object.getOwnPropertyNames(#object).length)
                  + ", fast properties " + HasFastProperties(#object));
          }
        ''', {"object": object, "objectString": js.string(object)}));
      }
    }

    return new jsAst.Block(parts);
  }

  void checkEverythingEmitted(
      Map<ClassEntity, ClassBuilder> pendingClassBuilders) {
    if (pendingClassBuilders == null) return;
    List<ClassEntity> pendingClasses =
        _sorter.sortClasses(pendingClassBuilders.keys);

    pendingClasses.forEach((ClassEntity element) => reporter.reportInfo(
        element, MessageKind.GENERIC, {'text': 'Pending statics.'}));

    if (pendingClasses != null && !pendingClasses.isEmpty) {
      reporter.internalError(
          pendingClasses.first, 'Pending statics (see above).');
    }
  }

  void assembleLibrary(Library library, Fragment fragment) {
    LibraryEntity libraryElement = library.element;

    assembleStaticFunctions(library.statics, fragment);

    ClassBuilder libraryBuilder =
        getLibraryDescriptor(libraryElement, fragment);
    for (Class cls in library.classes) {
      assembleClass(cls, libraryBuilder, fragment);
    }

    classEmitter.emitFields(library, libraryBuilder, emitStatics: true);
  }

  void assembleProgram(Program program) {
    for (Fragment fragment in program.fragments) {
      for (Library library in fragment.libraries) {
        assembleLibrary(library, fragment);
      }
    }
  }

  jsAst.Statement buildDeferredHeader() {
    /// For deferred loading we communicate the initializers via this global
    /// variable. The deferred hunks will add their initialization to this.
    /// The semicolon is important in minified mode, without it the
    /// following parenthesis looks like a call to the object literal.
    return js.statement(
        'self.#deferredInitializers = '
        'self.#deferredInitializers || Object.create(null);',
        {'deferredInitializers': deferredInitializers});
  }

  jsAst.Program buildOutputAstForMain(Program program,
      Map<OutputUnit, _DeferredOutputUnitHash> deferredLoadHashes) {
    MainFragment mainFragment = program.mainFragment;
    OutputUnit mainOutputUnit = mainFragment.outputUnit;
    bool isProgramSplit = program.isSplit;

    List<jsAst.Statement> statements = <jsAst.Statement>[];

    statements..add(buildGeneratedBy())..add(js.comment(HOOKS_API_USAGE));

    if (isProgramSplit) {
      statements.add(buildDeferredHeader());
    }

    // Collect the AST for the descriptors.
    Map<LibraryEntity, ClassBuilder> descriptors =
        libraryDescriptors[mainFragment] ?? const {};

    checkEverythingEmitted(classDescriptors[mainFragment]);

    Iterable<LibraryEntity> libraries = outputLibraryLists[mainOutputUnit];
    if (libraries == null) libraries = <LibraryEntity>[];

    List<jsAst.Expression> parts = <jsAst.Expression>[];
    for (LibraryEntity library in _sorter.sortLibraries(libraries)) {
      parts.add(generateLibraryDescriptor(library, mainFragment));
      descriptors.remove(library);
    }

    if (descriptors.isNotEmpty) {
      List<LibraryEntity> remainingLibraries = descriptors.keys.toList();

      // The remaining descriptors are only accessible through reflection.
      // The program builder does not collect libraries that only
      // contain typedefs that are used for reflection.
      for (LibraryEntity element in remainingLibraries) {
        parts.add(generateLibraryDescriptor(element, mainFragment));
        descriptors.remove(element);
      }
    }
    jsAst.ArrayInitializer descriptorsAst = new jsAst.ArrayInitializer(parts);

    // Using a named function here produces easier to read stack traces in
    // Chrome/V8.
    statements.add(js.statement("""
    (function() {
       // No renaming in the top-level function to save the locals for the
       // nested context where they will be used more. We have to put the
       // comment into a hole as the parser strips out comments right away.
       #disableVariableRenaming;
       #supportsDirectProtoAccess;

       if (#isProgramSplit) {
         /// We collect all the global state, so it can be passed to the
         /// initializer of deferred files.
         var #globalsHolder = Object.create(null)
       }

       // [map] returns an object that V8 shouldn't try to optimize with a
       // hidden class. This prevents a potential performance problem where V8
       // tries to build a hidden class for an object used as a hashMap.
       // It requires fewer characters to declare a variable as a parameter than
       // with `var`.
       function map(x) {
         x = Object.create(null);
         x.x = 0;
         delete x.x;
         return x;
       }

       #globalObjectSetup;

       function #isolateName() {}

       if (#isProgramSplit) {
         #globalsHolder.#isolateName = #isolateName;
         #globalsHolder.#initName = #initName;
         #globalsHolder.#setupProgramName = #setupProgramName;
       }

       init();

       #cspPrecompiledFunctions;

       #setupProgram;

       #functionThatReturnsNull;

       // The argument to reflectionDataParser is assigned to a temporary 'dart'
       // so that 'dart.' will appear as the prefix to dart methods in stack
       // traces and profile entries.
       var dart = #descriptors;

       #setupProgramName(dart, 0, 0);

       #getInterceptorMethods;
       #oneShotInterceptors;

       #makeConstantList;

       // We abuse the short name used for the isolate here to store
       // the isolate properties. This is safe as long as the real isolate
       // object does not exist yet.
       var ${namer.staticStateHolder} = #isolatePropertiesName;

       // Constants in checked mode call into RTI code to set type information
       // which may need getInterceptor (and one-shot interceptor) methods, so
       // we have to make sure that [emitGetInterceptorMethods] and
       // [emitOneShotInterceptors] have been called.
       #compileTimeConstants;

       // Static field initializations require the classes and compile-time
       // constants to be set up.
       #staticNonFinalInitializers;

       ${namer.staticStateHolder} = null;

       #deferredBoilerPlate;

       #typeToInterceptorMap;

       #lazyStaticFields;

       #isolateName = $finishIsolateConstructorName(#isolateName);

       ${namer.staticStateHolder} = new #isolateName();

       #metadata;

       #convertToFastObject;
       #convertToSlowObject;

       #convertGlobalObjectsToFastObjects;
       #debugFastObjects;

       #init;

       #main;
    })();
    """, {
      "disableVariableRenaming": js.comment("/* ::norenaming:: */"),
      "isProgramSplit": isProgramSplit,
      "supportsDirectProtoAccess": buildSupportsDirectProtoAccess(),
      "globalsHolder": globalsHolder,
      "globalObjectSetup": buildGlobalObjectSetup(isProgramSplit),
      "isolateName": namer.isolateName,
      "isolatePropertiesName": js(isolatePropertiesName),
      "initName": initName,
      "functionThatReturnsNull": buildFunctionThatReturnsNull(),
      "setupProgram": buildSetupProgram(
          program, compiler, backend, namer, this, _closedWorld),
      "setupProgramName": setupProgramName,
      "descriptors": descriptorsAst,
      "cspPrecompiledFunctions": buildCspPrecompiledFunctionFor(mainOutputUnit),
      "getInterceptorMethods": interceptorEmitter.buildGetInterceptorMethods(),
      "oneShotInterceptors": interceptorEmitter.buildOneShotInterceptors(),
      "makeConstantList":
          buildMakeConstantList(program.outputContainsConstantList),
      "compileTimeConstants": buildCompileTimeConstants(mainFragment.constants,
          isMainFragment: true),
      "deferredBoilerPlate": buildDeferredBoilerPlate(deferredLoadHashes),
      "staticNonFinalInitializers":
          buildStaticNonFinalFieldInitializations(mainOutputUnit),
      "typeToInterceptorMap":
          interceptorEmitter.buildTypeToInterceptorMap(program),
      "lazyStaticFields": buildLazilyInitializedStaticFields(
          mainFragment.staticLazilyInitializedFields),
      "metadata": buildMetadata(program, mainOutputUnit),
      "convertToFastObject": buildConvertToFastObjectFunction(),
      "convertToSlowObject": buildConvertToSlowObjectFunction(),
      "convertGlobalObjectsToFastObjects":
          buildConvertGlobalObjectToFastObjects(),
      "debugFastObjects": buildDebugFastObjectCode(),
      "init": buildInitFunction(program.outputContainsConstantList),
      "main": buildMain(mainFragment.invokeMain)
    }));

    return new jsAst.Program(statements);
  }

  void emitMainOutputUnit(OutputUnit mainOutputUnit, jsAst.Program program) {
    LocationCollector locationCollector;
    List<CodeOutputListener> codeOutputListeners;
    if (generateSourceMap) {
      locationCollector = new LocationCollector();
      codeOutputListeners = <CodeOutputListener>[locationCollector];
    }

    CodeOutput mainOutput = new StreamCodeOutput(
        compiler.outputProvider.createOutputSink('', 'js', OutputType.js),
        codeOutputListeners);
    outputBuffers[mainOutputUnit] = mainOutput;

    mainOutput.addBuffer(jsAst.createCodeBuffer(
        program, compiler.options, backend.sourceInformationStrategy,
        monitor: compiler.dumpInfoTask));

    if (compiler.options.deferredMapUri != null) {
      outputDeferredMap();
    }

    if (generateSourceMap) {
      mainOutput.add(SourceMapBuilder.generateSourceMapTag(
          compiler.options.sourceMapUri, compiler.options.outputUri));
    }

    mainOutput.close();

    if (generateSourceMap) {
      SourceMapBuilder.outputSourceMap(
          mainOutput,
          locationCollector,
          namer.createMinifiedGlobalNameMap(),
          namer.createMinifiedInstanceNameMap(),
          '',
          compiler.options.sourceMapUri,
          compiler.options.outputUri,
          compiler.outputProvider);
    }
  }

  Map<OutputUnit, jsAst.Expression> buildDescriptorsForOutputUnits(
      Program program) {
    Map<OutputUnit, jsAst.Expression> outputs =
        new Map<OutputUnit, jsAst.Expression>();

    for (Fragment fragment in program.deferredFragments) {
      OutputUnit outputUnit = fragment.outputUnit;

      Map<LibraryEntity, ClassBuilder> descriptors =
          libraryDescriptors[fragment];

      if (descriptors != null && descriptors.isNotEmpty) {
        Iterable<LibraryEntity> libraries = outputLibraryLists[outputUnit];
        if (libraries == null) libraries = <LibraryEntity>[];

        // TODO(johnniwinther): Avoid creating [CodeBuffer]s.
        List<jsAst.Expression> parts = <jsAst.Expression>[];
        for (LibraryEntity library in _sorter.sortLibraries(libraries)) {
          parts.add(generateLibraryDescriptor(library, fragment));
          descriptors.remove(library);
        }

        outputs[outputUnit] = new jsAst.ArrayInitializer(parts);
      }
    }

    return outputs;
  }

  void finalizeTokensInAst(
      jsAst.Program main, Iterable<jsAst.Program> deferredParts) {
    jsAst.TokenCounter counter = new jsAst.TokenCounter();
    counter.countTokens(main);
    deferredParts.forEach(counter.countTokens);
    task.metadataCollector.finalizeTokens();
    if (backend.namer is jsAst.TokenFinalizer) {
      dynamic finalizer = backend.namer;
      finalizer.finalizeTokens();
    }
  }

  int emitProgram(ProgramBuilder programBuilder) {
    Program program =
        programBuilder.buildProgram(storeFunctionTypesInMetadata: true);
    if (retainDataForTesting) {
      programForTesting = program;
    }

    outputStaticNonFinalFieldLists =
        programBuilder.collector.outputStaticNonFinalFieldLists;
    outputLibraryLists = programBuilder.collector.outputLibraryLists;

    assembleProgram(program);

    // Construct the ASTs for all deferred output units.
    Map<OutputUnit, jsAst.Program> deferredParts =
        buildOutputAstForDeferredCode(program);

    Map<OutputUnit, _DeferredOutputUnitHash> deferredHashTokens =
        new Map<OutputUnit, _DeferredOutputUnitHash>.fromIterables(
            deferredParts.keys, deferredParts.keys.map((OutputUnit unit) {
      return new _DeferredOutputUnitHash(unit);
    }));

    jsAst.Program mainOutput =
        buildOutputAstForMain(program, deferredHashTokens);

    finalizeTokensInAst(mainOutput, deferredParts.values);

    // Emit deferred units first, so we have their hashes.
    // Map from OutputUnit to a hash of its content. The hash uniquely
    // identifies the code of the output-unit. It does not include
    // boilerplate JS code, like the sourcemap directives or the hash
    // itself.
    Map<OutputUnit, String> deferredLoadHashes =
        emitDeferredOutputUnits(deferredParts);

    deferredHashTokens.forEach((OutputUnit key, _DeferredOutputUnitHash token) {
      token.setHash(deferredLoadHashes[key]);
    });
    emitMainOutputUnit(program.mainFragment.outputUnit, mainOutput);

    if (_closedWorld.backendUsage.requiresPreamble &&
        !backend.htmlLibraryIsLoaded) {
      reporter.reportHintMessage(NO_LOCATION_SPANNABLE, MessageKind.PREAMBLE);
    }
    // Return the total program size.
    return outputBuffers.values.fold(0, (a, b) => a + b.length);
  }

  ClassBuilder getStaticMethodDescriptor(
      FunctionEntity element, Fragment fragment) {
    if (!_nativeData.isNativeMember(element)) {
      // For static (not top level) elements, record their code in a buffer
      // specific to the class. For now, not supported for native classes and
      // native elements.
      ClassEntity cls = element.enclosingClass;
      if (compiler.codegenWorldBuilder.directlyInstantiatedClasses
              .contains(cls) &&
          !_nativeData.isNativeClass(cls) &&
          _outputUnitData.outputUnitForMember(element) ==
              _outputUnitData.outputUnitForClass(cls)) {
        return classDescriptors
            .putIfAbsent(fragment, () => new Map<ClassEntity, ClassBuilder>())
            .putIfAbsent(cls, () {
          return new ClassBuilder.forClass(cls, namer);
        });
      }
    }
    return _getLibraryDescriptor(element, element.library, fragment);
  }

  ClassBuilder getLibraryDescriptor(LibraryEntity element, Fragment fragment) {
    return _getLibraryDescriptor(element, element, fragment);
  }

  ClassBuilder _getLibraryDescriptor(
      Entity element, LibraryEntity owner, Fragment fragment) {
    if (owner == null) {
      reporter.internalError(element, 'Owner is null.');
    }
    return libraryDescriptors
        .putIfAbsent(fragment, () => new Map<LibraryEntity, ClassBuilder>())
        .putIfAbsent(owner, () {
      return new ClassBuilder.forLibrary(owner, namer);
    });
  }

  /// Emits support-code for deferred loading into [output].
  jsAst.Statement buildDeferredBoilerPlate(
      Map<OutputUnit, _DeferredOutputUnitHash> deferredLoadHashes) {
    List<jsAst.Statement> parts = <jsAst.Statement>[];

    parts.add(js.statement('''
        {
          // Function for checking if a hunk is loaded given its hash.
          #isHunkLoaded = function(hunkHash) {
            return !!$deferredInitializers[hunkHash];
          };
          #deferredInitialized = new Object(null);
          // Function for checking if a hunk is initialized given its hash.
          #isHunkInitialized = function(hunkHash) {
            return #deferredInitialized[hunkHash];
          };
          // Function for initializing a loaded hunk, given its hash.
          #initializeLoadedHunk = function(hunkHash) {
            var hunk = $deferredInitializers[hunkHash];
            if (hunk == null) {
                throw "DeferredLoading state error: code with hash '" +
                    hunkHash + "' was not loaded";
            }
            hunk(#globalsHolder, ${namer.staticStateHolder});
            #deferredInitialized[hunkHash] = true;
          };
        }
        ''', {
      "globalsHolder": globalsHolder,
      "isHunkLoaded":
          generateEmbeddedGlobalAccess(embeddedNames.IS_HUNK_LOADED),
      "isHunkInitialized":
          generateEmbeddedGlobalAccess(embeddedNames.IS_HUNK_INITIALIZED),
      "initializeLoadedHunk":
          generateEmbeddedGlobalAccess(embeddedNames.INITIALIZE_LOADED_HUNK),
      "deferredInitialized":
          generateEmbeddedGlobalAccess(embeddedNames.DEFERRED_INITIALIZED)
    }));

    void store(
        jsAst.Expression map, jsAst.Expression uris, jsAst.Expression hashes) {
      void assign(String name, jsAst.Expression value) {
        parts.add(
            js.statement('# = #', [generateEmbeddedGlobalAccess(name), value]));
      }

      assign(embeddedNames.DEFERRED_LIBRARY_PARTS, map);
      assign(embeddedNames.DEFERRED_PART_URIS, uris);
      assign(embeddedNames.DEFERRED_PART_HASHES, hashes);
    }

    createDeferredLoadingData(
        _closedWorld.outputUnitData.hunksToLoad, deferredLoadHashes, store);

    return new jsAst.Block(parts);
  }

  // Create data used for loading and initializing the hunks for a deferred
  // import. There are three parts: a map from loadId to list of parts, where
  // parts are represented as an index; an array of uris indexed by part; and an
  // array of hashes indexed by part.
  void createDeferredLoadingData(
      Map<String, List<OutputUnit>> loadMap,
      Map<OutputUnit, _DeferredOutputUnitHash> deferredLoadHashes,
      void finish(jsAst.Expression map, jsAst.Expression uris,
          jsAst.Expression hashes)) {
    Map<OutputUnit, int> fragmentIndexes = <OutputUnit, int>{};
    var uris = <jsAst.Expression>[];
    var hashes = <jsAst.Expression>[];

    List<jsAst.Property> libraryPartsMapEntries = <jsAst.Property>[];

    loadMap.forEach((String loadId, List<OutputUnit> fragmentList) {
      List<jsAst.Expression> indexes = <jsAst.Expression>[];
      for (OutputUnit fragment in fragmentList) {
        int index = fragmentIndexes[fragment];
        if (index == null) {
          index = fragmentIndexes[fragment] = fragmentIndexes.length;
          uris.add(js.escapedString(
              deferredPartFileName(compiler.options, fragment.name)));
          _DeferredOutputUnitHash hash = deferredLoadHashes[fragment];
          assert(hash != null, "No hash for $fragment in $deferredLoadHashes.");
          hashes.add(hash);
        }
        indexes.add(js.number(index));
      }
      libraryPartsMapEntries.add(new jsAst.Property(
          js.string(loadId), new jsAst.ArrayInitializer(indexes)));
    });

    finish(new jsAst.ObjectInitializer(libraryPartsMapEntries),
        new jsAst.ArrayInitializer(uris), new jsAst.ArrayInitializer(hashes));
  }

  Map<OutputUnit, jsAst.Program> buildOutputAstForDeferredCode(
      Program program) {
    if (!program.isSplit) return const <OutputUnit, jsAst.Program>{};

    Map<OutputUnit, jsAst.Program> result =
        new Map<OutputUnit, jsAst.Program>();

    Map<OutputUnit, jsAst.Expression> deferredAsts =
        buildDescriptorsForOutputUnits(program);

    for (Fragment fragment in program.deferredFragments) {
      OutputUnit outputUnit = fragment.outputUnit;
      jsAst.Expression libraryDescriptor = deferredAsts[outputUnit];
      List<jsAst.Statement> body = <jsAst.Statement>[];

      // No renaming in the top-level function to save the locals for the
      // nested context where they will be used more.
      body.add(js.comment("/* ::norenaming:: "));

      for (String globalObject in Namer.reservedGlobalObjectNames) {
        body.add(js.statement('var #object = #globalsHolder.#object;',
            {'globalsHolder': globalsHolder, 'object': globalObject}));
      }
      body
        ..add(js.statement('var init = #globalsHolder.init;',
            {'globalsHolder': globalsHolder}))
        ..add(js.statement(
            'var $setupProgramName = '
            '#globalsHolder.$setupProgramName;',
            {'globalsHolder': globalsHolder}))
        ..add(js.statement(
            'var ${namer.isolateName} = '
            '#globalsHolder.${namer.isolateName};',
            {'globalsHolder': globalsHolder}));
      String metadataAccess =
          generateEmbeddedGlobalAccessString(embeddedNames.METADATA);
      String typesAccess =
          generateEmbeddedGlobalAccessString(embeddedNames.TYPES);
      if (libraryDescriptor != null) {
        // The argument to reflectionDataParser is assigned to a temporary
        // 'dart' so that 'dart.' will appear as the prefix to dart methods
        // in stack traces and profile entries.
        body.add(js.statement('var dart = #', libraryDescriptor));

        if (compiler.options.useContentSecurityPolicy) {
          body.add(buildCspPrecompiledFunctionFor(outputUnit));
        }
        body.add(js.statement('$setupProgramName('
            'dart, ${metadataAccess}.length, ${typesAccess}.length);'));
      }

      body
        ..add(buildMetadata(program, outputUnit))
        ..add(js.statement('${metadataAccess}.push.apply(${metadataAccess}, '
            '${namer.deferredMetadataName});'))
        ..add(js.statement('${typesAccess}.push.apply(${typesAccess}, '
            '${namer.deferredTypesName});'));

      body.add(
          buildCompileTimeConstants(fragment.constants, isMainFragment: false));
      body.add(buildStaticNonFinalFieldInitializations(outputUnit));
      body.add(buildLazilyInitializedStaticFields(
          fragment.staticLazilyInitializedFields,
          isMainFragment: false));

      List<jsAst.Statement> statements = <jsAst.Statement>[];

      statements
        ..add(buildGeneratedBy())
        ..add(buildDeferredHeader())
        ..add(js.statement(
            '${deferredInitializers}.current = '
            """function (#, ${namer.staticStateHolder}) {
                                  #
                                }
                             """,
            [globalsHolder, body]));

      result[outputUnit] = new jsAst.Program(statements);
    }

    return result;
  }

  /// Returns a map from OutputUnit to a hash of its content. The hash uniquely
  /// identifies the code of the output-unit. It does not include
  /// boilerplate JS code, like the sourcemap directives or the hash
  /// itself.
  Map<OutputUnit, String> emitDeferredOutputUnits(
      Map<OutputUnit, jsAst.Program> outputAsts) {
    Map<OutputUnit, String> hunkHashes = new Map<OutputUnit, String>();

    for (OutputUnit outputUnit in outputAsts.keys) {
      List<CodeOutputListener> outputListeners = <CodeOutputListener>[];
      Hasher hasher = new Hasher();
      outputListeners.add(hasher);

      LocationCollector locationCollector;
      if (generateSourceMap) {
        locationCollector = new LocationCollector();
        outputListeners.add(locationCollector);
      }

      String partPrefix = deferredPartFileName(
          compiler.options, outputUnit.name,
          addExtension: false);
      CodeOutput output = new StreamCodeOutput(
          compiler.outputProvider
              .createOutputSink(partPrefix, 'part.js', OutputType.jsPart),
          outputListeners);

      outputBuffers[outputUnit] = output;

      output.addBuffer(jsAst.createCodeBuffer(outputAsts[outputUnit],
          compiler.options, backend.sourceInformationStrategy,
          monitor: compiler.dumpInfoTask));

      // Make a unique hash of the code (before the sourcemaps are added)
      // This will be used to retrieve the initializing function from the global
      // variable.
      String hash = hasher.getHash();

      output.add('$N${deferredInitializers}["$hash"]$_=$_'
          '${deferredInitializers}.current$N');

      if (generateSourceMap) {
        Uri mapUri, partUri;
        Uri sourceMapUri = compiler.options.sourceMapUri;
        Uri outputUri = compiler.options.outputUri;

        String partName = "$partPrefix.part";

        if (sourceMapUri != null) {
          String mapFileName = partName + ".js.map";
          List<String> mapSegments = sourceMapUri.pathSegments.toList();
          mapSegments[mapSegments.length - 1] = mapFileName;
          mapUri =
              compiler.options.sourceMapUri.replace(pathSegments: mapSegments);
        }

        if (outputUri != null) {
          String partFileName = partName + ".js";
          List<String> partSegments = outputUri.pathSegments.toList();
          partSegments[partSegments.length - 1] = partFileName;
          partUri =
              compiler.options.outputUri.replace(pathSegments: partSegments);
        }

        output.add(SourceMapBuilder.generateSourceMapTag(mapUri, partUri));
        output.close();
        SourceMapBuilder.outputSourceMap(output, locationCollector, {}, {},
            partName, mapUri, partUri, compiler.outputProvider);
      } else {
        output.close();
      }

      hunkHashes[outputUnit] = hash;
    }
    return hunkHashes;
  }

  jsAst.Comment buildGeneratedBy() {
    StringBuffer flavor = new StringBuffer();
    flavor.write('full emitter');
    // TODO(johnniwinther): Remove this flavor.
    flavor.write(', strong');
    if (compiler.options.trustPrimitives) flavor.write(', trust primitives');
    if (compiler.options.omitImplicitChecks) flavor.write(', omit checks');
    if (compiler.options.laxRuntimeTypeToString) {
      flavor.write(', lax runtime type');
    }
    if (compiler.options.useContentSecurityPolicy) flavor.write(', CSP');
    if (_closedWorld.backendUsage.isMirrorsUsed) flavor.write(', mirrors');
    return new jsAst.Comment(generatedBy(compiler, flavor: '$flavor'));
  }

  void outputDeferredMap() {
    Map<String, dynamic> mapping = new Map<String, dynamic>();
    // Json does not support comments, so we embed the explanation in the
    // data.
    mapping["_comment"] = "This mapping shows which compiled `.js` files are "
        "needed for a given deferred library import.";
    mapping.addAll(_closedWorld.outputUnitData
        .computeDeferredMap(compiler.options, _elementEnvironment));
    compiler.outputProvider.createOutputSink(
        compiler.options.deferredMapUri.path, '', OutputType.info)
      ..add(const JsonEncoder.withIndent("  ").convert(mapping))
      ..close();
  }
}
