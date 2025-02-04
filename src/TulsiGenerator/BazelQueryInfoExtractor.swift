// Copyright 2016 The Tulsi Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation


// Provides methods utilizing Bazel query (http://bazel.build/docs/query.html) to extract
// information from a workspace.
final class BazelQueryInfoExtractor: QueuedLogging {

  enum ExtractorError: Error {
    /// A valid Bazel binary could not be located.
    case invalidBazelPath
  }

  /// The location of the bazel binary.
  var bazelURL: URL
  /// The location of the directory in which the workspace enclosing this BUILD file can be found.
  let workspaceRootURL: URL
  /// Universal flags for all Bazel invocations.
  private let bazelUniversalFlags: BazelFlags

  private let localizedMessageLogger: LocalizedMessageLogger
  private var queuedInfoMessages = [String]()

  private typealias CompletionHandler = (Process, Data, String?, String) -> Void

  init(bazelURL: URL,
       workspaceRootURL: URL,
       bazelUniversalFlags: BazelFlags,
       localizedMessageLogger: LocalizedMessageLogger) {
    self.bazelURL = bazelURL
    self.workspaceRootURL = workspaceRootURL
    self.bazelUniversalFlags = bazelUniversalFlags
    self.localizedMessageLogger = localizedMessageLogger
  }

    
    /// Extracts all of the transitive BUILD and skylark (.bzl) files used by the given targets.
    func extractRuleEntriesfromTargets<T: Collection>(_ targets: T) -> RuleEntryMap where T.Iterator.Element == BuildLabel
    {
      if targets.isEmpty { return RuleEntryMap() }

      let profilingStart = localizedMessageLogger.startProfiling("extracting_rule_entrys_by_query",
                                                                 message: "Finding rule entrys for \(targets.count) rules")


      let query = targets.map({ "kind(rule, deps(\($0.value)))"}).joined(separator: "+")
      let entryMap: RuleEntryMap
      do {
        // Errors in the BUILD structure being examined should not prevent partial extraction, so this
        // command is considered successful if it returns any valid data at all.
        let (_, data, _, debugInfo) = try self.bazelSynchronousQueryProcess(query,
                                                                             outputKind: "xml",
                                                                            additionalArguments: ["--keep_going"],
                                                                            loggingIdentifier: "bazel_query_extracting_skylark_files")
        self.queuedInfoMessages.append(debugInfo)

        if let ruleEntries = try extractRuleEntriesFromXMLOutput(data) {
            entryMap = ruleEntries
        } else {
          localizedMessageLogger.warning("BazelBuildfilesQueryFailed",
                                         comment: "Bazel 'rule' query failed to extract information.")
            entryMap = RuleEntryMap()
        }

        localizedMessageLogger.logProfilingEnd(profilingStart)
      } catch {
        // Error will be displayed at the end of project generation.
        return RuleEntryMap()
      }

      return entryMap
    }

    
  func extractTargetRulesFromPackages(_ packages: [String]) -> [RuleInfo] {
    guard !packages.isEmpty else {
      return []
    }

    let profilingStart = localizedMessageLogger.startProfiling("fetch_rules",
                                                               message: "Fetching rules for packages \(packages)")
    var infos = [RuleInfo]()
    let query = packages.map({ "kind(rule, \($0):all)"}).joined(separator: "+")
    do {
      let (process, data, stderr, debugInfo) =
          try self.bazelSynchronousQueryProcess(query,
                                                outputKind: "xml",
                                                loggingIdentifier: "bazel_query_fetch_rules")
      if process.terminationStatus != 0 {
         showExtractionError(debugInfo, stderr: stderr, displayLastLineIfNoErrorLines: true)
      } else if let entries = self.extractRuleInfosFromBazelXMLOutput(data) {
        infos = entries
      }
    } catch {
      // The error has already been displayed to the user.
      return []
    }

    localizedMessageLogger.logProfilingEnd(profilingStart)
    return infos
  }

  /// Extracts all of the transitive BUILD and skylark (.bzl) files used by the given targets.
  func extractBuildfiles<T: Collection>(_ targets: T) -> Set<BuildLabel> where T.Iterator.Element == BuildLabel {
    if targets.isEmpty { return Set() }

    let profilingStart = localizedMessageLogger.startProfiling("extracting_skylark_files",
                                                               message: "Finding Skylark files for \(targets.count) rules")

    let labelDeps = targets.map {"deps(\($0.value))"}
    let joinedLabelDeps = labelDeps.joined(separator: "+")
    let query = "buildfiles(\(joinedLabelDeps))"
    let buildFiles: Set<BuildLabel>
    do {
      // Errors in the BUILD structure being examined should not prevent partial extraction, so this
      // command is considered successful if it returns any valid data at all.
      let (_, data, _, debugInfo) = try self.bazelSynchronousQueryProcess(query,
                                                                          outputKind: "xml",
                                                                          additionalArguments: ["--keep_going"],
                                                                          loggingIdentifier: "bazel_query_extracting_skylark_files")
      self.queuedInfoMessages.append(debugInfo)

      if let labels = extractSourceFileLabelsFromBazelXMLOutput(data) {
        buildFiles = Set(labels)
      } else {
        localizedMessageLogger.warning("BazelBuildfilesQueryFailed",
                                       comment: "Bazel 'buildfiles' query failed to extract information.")
        buildFiles = Set()
      }

      localizedMessageLogger.logProfilingEnd(profilingStart)
    } catch {
      // Error will be displayed at the end of project generation.
      return Set()
    }

    return buildFiles
  }

  // MARK: - Private methods

  private func showExtractionError(_ debugInfo: String,
                                   stderr: String?,
                                   displayLastLineIfNoErrorLines: Bool = false) {
    localizedMessageLogger.infoMessage(debugInfo)
    let details: String?
    if let stderr = stderr {
      if displayLastLineIfNoErrorLines {
        details = BazelErrorExtractor.firstErrorLinesOrLastLinesFromString(stderr)
      } else {
        details = BazelErrorExtractor.firstErrorLinesFromString(stderr)
      }
    } else {
      details = nil
    }
    localizedMessageLogger.error("BazelInfoExtractionFailed",
                                 comment: "Error message for when a Bazel extractor did not complete successfully. Details are logged separately.",
                                 details: details)
  }

  // Generates a Process that will perform a bazel query, capturing the output data and passing it
  // to the terminationHandler.
  private func bazelQueryProcess(_ query: String,
                                 outputKind: String? = nil,
                                 additionalArguments: [String] = [],
                                 message: String = "",
                                 loggingIdentifier: String? = nil,
                                 terminationHandler: @escaping CompletionHandler) throws -> Process {
    guard FileManager.default.fileExists(atPath: bazelURL.path) else {
      localizedMessageLogger.error("BazelBinaryNotFound",
                                   comment: "Error to show when the bazel binary cannot be found at the previously saved location %1$@.",
                                   values: bazelURL as NSURL)
      throw ExtractorError.invalidBazelPath
    }

    var arguments = [
        "--max_idle_secs=60",
    ]
    arguments.append(contentsOf: bazelUniversalFlags.startup)
    arguments.append("query")
    arguments.append(contentsOf: bazelUniversalFlags.build)
    arguments.append(contentsOf: [
        "--announce_rc",  // Print the RC files used by this operation.
        "--noimplicit_deps",
        "--order_output=no",
        "--noshow_loading_progress",
        "--noshow_progress",
        query
    ])
    arguments.append(contentsOf: additionalArguments)
    if let kind = outputKind {
      arguments.append(contentsOf: ["--output", kind])
    }

    var message = message
    if message != "" {
      message = "\(message)\n"
    }

    let process = TulsiProcessRunner.createProcess(bazelURL.path,
                                                   arguments: arguments,
                                                   messageLogger: localizedMessageLogger,
                                                   loggingIdentifier: loggingIdentifier) {
      completionInfo in
        let debugInfoFormatString = NSLocalizedString("DebugInfoForBazelCommand",
                                                      bundle: Bundle(for: type(of: self)),
                                                      comment: "Provides general information about a Bazel failure; a more detailed error may be reported elsewhere. The Bazel command is %1$@, exit code is %2$d, stderr %3$@.")
        let stderr = NSString(data: completionInfo.stderr, encoding: String.Encoding.utf8.rawValue)
        let debugInfo = String(format: debugInfoFormatString,
                               completionInfo.commandlineString,
                               completionInfo.terminationStatus,
                               stderr ?? "<No STDERR>")

      terminationHandler(completionInfo.process,
                         completionInfo.stdout,
                         stderr as String?,
                         debugInfo)
    }

    return process
  }

  /// Performs the given Bazel query synchronously in the workspaceRootURL directory.
  private func bazelSynchronousQueryProcess(_ query: String,
                                            outputKind: String? = nil,
                                            additionalArguments: [String] = [],
                                            message: String = "",
                                            loggingIdentifier: String? = nil) throws -> (bazelProcess: Process,
                                                                                         returnedData: Data,
                                                                                         stderrString: String?,
                                                                                         debugInfo: String) {
    let semaphore = DispatchSemaphore(value: 0)
    var data: Data! = nil
    var stderr: String? = nil
    var info: String! = nil

    let process = try bazelQueryProcess(query,
                                        outputKind: outputKind,
                                        additionalArguments: additionalArguments,
                                        message: message,
                                        loggingIdentifier: loggingIdentifier) {
      (_: Process, returnedData: Data, stderrString: String?, debugInfo: String) in
        data = returnedData
        stderr = stderrString
        info = debugInfo
      semaphore.signal()
    }

    process.currentDirectoryPath = workspaceRootURL.path
    process.launch()

    _ = semaphore.wait(timeout: DispatchTime.distantFuture)
    return (process, data, stderr, info)
  }

  private func extractRuleInfosWithRuleInputsFromBazelXMLOutput(_ bazelOutput: Data) -> [RuleInfo: Set<BuildLabel>]? {
    do {
      var infos = [RuleInfo: Set<BuildLabel>]()
      let doc = try XMLDocument(data: bazelOutput, options: XMLNode.Options(rawValue: 0))
      let rules = try doc.nodes(forXPath: "/query/rule")
      for ruleNode in rules {
        guard let ruleElement = ruleNode as? XMLElement else {
          localizedMessageLogger.error("BazelResponseXMLNonElementType",
                                       comment: "General error to show when the XML parser returns something other " +
                                               "than an NSXMLElement. This should never happen in practice.")
          continue
        }
        guard let ruleLabel = ruleElement.attribute(forName: "name")?.stringValue else {
          localizedMessageLogger.error("BazelResponseMissingRequiredAttribute",
                                       comment: "Bazel response XML element %1$@ was found but was missing an attribute named %2$@.",
                                       values: ruleElement, "name")
          continue
        }
        guard let ruleType = ruleElement.attribute(forName: "class")?.stringValue else {
          localizedMessageLogger.error("BazelResponseMissingRequiredAttribute",
                                       comment: "Bazel response XML element %1$@ was found but was missing an attribute named %2$@.",
                                       values: ruleElement, "class")
          continue
        }

        func extractLabelsFromXpath(_ xpath: String) throws -> Set<BuildLabel> {
          var labelSet = Set<BuildLabel>()
          let nodes = try ruleElement.nodes(forXPath: xpath)
          for node in nodes {
            guard let label = node.stringValue else {
              localizedMessageLogger.error("BazelResponseLabelAttributeInvalid",
                                           comment: "Bazel response XML element %1$@ should have a valid string value but does not.",
                                           values: node)
              continue
            }
            labelSet.insert(BuildLabel(label))
          }
          return labelSet
        }

        // Retrieve the list of linked targets through the test_host attribute. This provides a
        // link between the test target and the test host so they can be linked in Xcode.
        var linkedTargetLabels = Set<BuildLabel>()
        linkedTargetLabels.formUnion(
            try extractLabelsFromXpath("./label[@name='test_host']/@value"))

        let entry = RuleInfo(label: BuildLabel(ruleLabel),
                             type: ruleType,
                             linkedTargetLabels: linkedTargetLabels)

        infos[entry] = try extractLabelsFromXpath("./rule-input/@name")
      }
      return infos
    } catch let e as NSError {
      localizedMessageLogger.error("BazelResponseXMLParsingFailed",
                                   comment: "Extractor Bazel output failed to be parsed as XML with error %1$@. This may be a Bazel bug or a bad BUILD file.",
                                   values: e.localizedDescription)
      return nil
    }
  }

  private func extractRuleInfosFromBazelXMLOutput(_ bazelOutput: Data) -> [RuleInfo]? {
    if let infoMap = extractRuleInfosWithRuleInputsFromBazelXMLOutput(bazelOutput) {
      return [RuleInfo](infoMap.keys)
    }
    return nil
  }

  private func extractSourceFileLabelsFromBazelXMLOutput(_ bazelOutput: Data) -> Set<BuildLabel>? {
    do {
      let doc = try XMLDocument(data: bazelOutput, options: XMLNode.Options(rawValue: 0))
      let fileLabels = try doc.nodes(forXPath: "/query/source-file/@name")
      var extractedLabels = Set<BuildLabel>()
      for labelNode in fileLabels {
        guard let value = labelNode.stringValue else {
          localizedMessageLogger.error("BazelResponseLabelAttributeInvalid",
                                       comment: "Bazel response XML element %1$@ should have a valid string value but does not.",
                                       values: labelNode)
          continue
        }
        extractedLabels.insert(BuildLabel(value))
      }
      return extractedLabels
    } catch let e as NSError {
      localizedMessageLogger.error("BazelResponseXMLParsingFailed",
                                   comment: "Extractor Bazel output failed to be parsed as XML with error %1$@. This may be a Bazel bug or a bad BUILD file.",
                                   values: e.localizedDescription)
      return nil
    }
  }
    
private func extractRuleEntriesFromXMLOutput(_ bazelOutput: Data) throws ->  RuleEntryMap? {
    let profile = localizedMessageLogger.startProfiling("xml_decode_for_entries",message: "xml_decode_for_entries")
    let doc = try XMLDocument(data: bazelOutput, options: XMLNode.Options(rawValue: 0))
    
    localizedMessageLogger.logProfilingEnd(profile)
        
    let rules = try doc.nodes(forXPath: "/query/rule")
    
    let ruleEntryMap = RuleEntryMap(localizedMessageLogger: localizedMessageLogger)

    for ruleNode in rules {
      guard let ruleElement = ruleNode as? XMLElement else {
        localizedMessageLogger.error("BazelResponseXMLNonElementType",comment: "")
        continue
      }
      guard let ruleLabel = ruleElement.attribute(forName: "name")?.stringValue else {
        localizedMessageLogger.error("BazelResponseMissingRequiredAttribute",comment: "Bazel response XML element %1$@ was found but was missing an attribute named %2$@.",values: ruleElement, "name")
        continue
      }
      guard let ruleType = ruleElement.attribute(forName: "class")?.stringValue else {
        localizedMessageLogger.error("BazelResponseMissingRequiredAttribute",comment: "Bazel response XML element %1$@ was found but was missing an attribute named %2$@.",values: ruleElement, "class")
        continue
      }
      
      guard let location = ruleElement.attribute(forName: "location")?.stringValue else {
        localizedMessageLogger.error("BazelResponseMissingRequiredAttribute",comment: "Bazel response XML element %1$@ was found but was missing an attribute named %2$@.",values: ruleElement, "location")
        continue
      }
      
      var stringAttributes =  [String:String]()
      var labelAttributes = [String:BuildLabel]()
      var listAttributes = [String:[BuildLabel]]()

      let stringNodes = try ruleElement.nodes(forXPath: "./string")
      for attrNode in stringNodes {
          guard let attrElement = attrNode as? XMLElement else {
            localizedMessageLogger.error("BazelResponseXMLNonElementType",comment: " String parser")
            continue
          }
          if let name = attrElement.attribute(forName: "name")?.stringValue,let value =  attrElement.attribute(forName: "value")?.stringValue{
            stringAttributes[name] = value
          }
      }
    
      let labelNodes = try ruleElement.nodes(forXPath: "./label")
      for attrNode in labelNodes {
            guard let attrElement = attrNode as? XMLElement else {
              localizedMessageLogger.error("BazelResponseXMLNonElementType",comment: " Label parser")
              continue
            }
            if let name = attrElement.attribute(forName: "name")?.stringValue,let value =  attrElement.attribute(forName: "value")?.stringValue{
                labelAttributes[name] = BuildLabel(value)
            }
      }
        
        let listNodes = try ruleElement.nodes(forXPath: "./list")
        for attrNode in listNodes{
            guard let attrElement = attrNode as? XMLElement else {
              localizedMessageLogger.error("BazelResponseXMLNonElementType",comment: " list parser")
              continue
            }
        
            if let name = attrElement.attribute(forName: "name")?.stringValue{
                var attrSubElementArray = [BuildLabel]()
                if let subNodes =  attrElement.children{
                    for subNode in subNodes {
                        guard let attrSubElement = subNode as? XMLElement else {
                          localizedMessageLogger.error("BazelResponseXMLNonElementType",comment: " list sub string parser")
                          continue
                        }
                        if let value = attrSubElement.attribute(forName: "value")?.stringValue{
                            attrSubElementArray.append(BuildLabel(value))
                        }
                    }
                }
                listAttributes[name] = attrSubElementArray
            }
        }
        
        
        func MakeBazelFileInfos(_ attributeName: String) -> [BazelFileInfo] {
          let infos = listAttributes[attributeName] ?? []
          var bazelFileInfos = [BazelFileInfo]()
          for info in infos {
            let wrapInfo = ["path":info.asFileName,"src":true] as [String:AnyObject]
            if let pathInfo = BazelFileInfo(info: wrapInfo as AnyObject?) {
              bazelFileInfos.append(pathInfo)
            }
          }
          return bazelFileInfos
        }
        
        
        func makeBazelFileInfoDescription(_ attributeName: String) -> [[String: AnyObject]] {
            let infos = listAttributes[attributeName] ?? []
            var bazelFileInfos = [[String: AnyObject]]()
            for info in infos {
               let wrapInfo = ["path":info.asFileName,"src":true] as [String:AnyObject]
               bazelFileInfos.append(wrapInfo)
            }
            return bazelFileInfos
        }
        
        func makeSingleBazelFileInfoDescription(_ attributeName: String) -> [[String: AnyObject]] {
            if let info = labelAttributes[attributeName] {
                let wrapInfo = ["path":info.asFileName,"src":true] as [String:AnyObject]
                return [wrapInfo]
            }else{
                return []
            }
        }
        
    
        //
        let includePaths: [RuleEntry.IncludePath]?
        if let includes = listAttributes["includes"] as? [BuildLabel] {
          includePaths = includes.compactMap() {
            if let fileName = $0.asFileName{
                return RuleEntry.IncludePath(fileName, false)
            }
            return nil
          }
        } else {
          includePaths = nil
        }
        
        //
        let strings = location.components(separatedBy:":")
        var buildFilePath:String = ""
        if strings.count == 3 {
            buildFilePath = strings[0]
            let projectDir = workspaceRootURL.path
            if buildFilePath.contains(projectDir) {
                buildFilePath = buildFilePath.replacingOccurrences(of: projectDir, with: "")
                if buildFilePath.hasPrefix("/") {
                    buildFilePath.removeFirst()
                }
            }
        }
        
        var has_swift_info = false
        if let srcs = listAttributes["srcs"] {
            for src in srcs{
                if src.value.hasSuffix(".swift") {
                    has_swift_info = true
                    break
                }
            }
        }
        
        let copts:[String]
        if let coptsObj = listAttributes["copts"]{
            copts = coptsObj.map({$0.value})
        }else{
            copts = []
        }
        
        let defines:[String]
        if let definesObj = listAttributes["defines"]{
            defines = definesObj.map({$0.value})
        }else{
            defines = []
        }
        
        
        
        let isFileGroup = ruleType == "filegroup"
        
        if isFileGroup {
            print("")
        }
        let supportedfiles:[[String: AnyObject]] = isFileGroup ? makeBazelFileInfoDescription("srcs") : [[String: AnyObject]]()
        
//        let supportedfiles:[[String: AnyObject]] = makeBazelFileInfoDescription("data") + makeBazelFileInfoDescription("resources") + makeBazelFileInfoDescription("infoplists") + makeSingleBazelFileInfoDescription("src") + makeSingleBazelFileInfoDescription("entitlements")
        
        let attrs:[String: AnyObject] = [RuleEntry.Attribute.has_swift_info.rawValue:has_swift_info,
                                         RuleEntry.Attribute.copts.rawValue:copts,
                                         RuleEntry.Attribute.supporting_files.rawValue:supportedfiles
                                         ] as [String:AnyObject]
        
        let deps = listAttributes["deps"] ?? []
        let data = listAttributes["data"] ?? []
        let plists = listAttributes["infoplists"] ?? []
        let resources = listAttributes["resources"] ?? []

        let ruleEntry = RuleEntry(label: ruleLabel,
                                  type: ruleType,
                                  attributes: attrs,
                                  artifacts: MakeBazelFileInfos("artifacts"),
                                  sourceFiles: MakeBazelFileInfos("srcs") + MakeBazelFileInfos("hdrs") ,
                                  nonARCSourceFiles: MakeBazelFileInfos("non_arc_srcs"),
                                  dependencies:Set(deps+data+plists+resources),
                                  testDependencies: [],
                                  frameworkImports: MakeBazelFileInfos("frameworks"),
                                  secondaryArtifacts: [],
                                  extensions: [],
                                  appClips: [],
                                  bundleID: stringAttributes["bundle_id"],
                                  bundleName: stringAttributes["name"],
                                  productType: PBXTarget.ProductType(rawValue: stringAttributes["product_type"] ?? ""),
                                  platformType: stringAttributes["platform_type"] ?? "ios",
                                  osDeploymentTarget: stringAttributes["minimum_os_version"] ?? "9.0",
                                  buildFilePath: buildFilePath,
                                  objcDefines: has_swift_info ? [] : defines,
                                  swiftDefines: has_swift_info ? defines : [],
                                  includePaths: includePaths,
                                  swiftLanguageVersion: "5.3",
                                  swiftToolchain: "",
                                  swiftTransitiveModules: [],
                                  objCModuleMaps: [],
                                  moduleName: stringAttributes["moduleName"],
                                  extensionType: "",
                                  xcodeVersion: "")
        ruleEntryMap.insert(ruleEntry: ruleEntry)
    }
    
    return ruleEntryMap
}
    

    
    
    
  // MARK: - QueuedLogging

  func logQueuedInfoMessages() {
    guard !self.queuedInfoMessages.isEmpty else {
      return
    }
    localizedMessageLogger.debugMessage("Log of Bazel query output follows:")
    for message in self.queuedInfoMessages {
      localizedMessageLogger.debugMessage(message)
    }
    self.queuedInfoMessages.removeAll()
  }

  var hasQueuedInfoMessages: Bool {
    return !self.queuedInfoMessages.isEmpty
  }
}
