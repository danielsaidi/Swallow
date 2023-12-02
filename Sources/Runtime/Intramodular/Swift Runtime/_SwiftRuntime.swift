//
// Copyright (c) Vatsal Manot
//

import MachO
import Diagnostics
import Foundation
import Swallow

public struct _SwiftRuntime {
    
}

extension _SwiftRuntime {
    private static func getTypeName(
        descriptor: UnsafePointer<_SwiftRuntime.TargetModuleContextDescriptor>
    ) -> String? {
        let flags = descriptor.pointee.flags
        var parentName: String? = nil
        switch flags.kind {
            case .Module, .Enum, .Struct, .Class:
                let name = UnsafeRawPointer(descriptor)
                    .advanced(by: MemoryLayout<_SwiftRuntime.TargetModuleContextDescriptor>.offset(of: \.name)!)
                    .advanced(by: Int(descriptor.pointee.name))
                    .assumingMemoryBound(to: CChar.self)
                let typeName = String(cString: name)
                if descriptor.pointee.parent != 0 {
                    let parent = UnsafeRawPointer(descriptor).advanced(by: MemoryLayout<_SwiftRuntime.TargetModuleContextDescriptor>.offset(of: \.parent)!).advanced(by: Int(descriptor.pointee.parent))
                    if abs(descriptor.pointee.parent) % 2 == 1 {
                        return nil
                    }
                    parentName = getTypeName(descriptor: parent.assumingMemoryBound(to: _SwiftRuntime.TargetModuleContextDescriptor.self))
                }
                if let parentName = parentName {
                    return "\(parentName).\(typeName)"
                }
                return typeName
            default:
                return nil
        }
    }
    
    public typealias LookupResult = (name: String, accessor: () -> UInt64, proto: String)
    
    private static func parseConformance(
        conformance: UnsafePointer<_SwiftRuntime.ProtocolConformanceDescriptor>
    ) -> LookupResult? {
        let flags = conformance.pointee.conformanceFlags
        
        guard case .DirectTypeDescriptor = flags.kind else {
            return nil
        }
        
        guard conformance.pointee.protocolDescriptor % 2 == 1 else {
            return nil
        }
        let descriptorOffset = Int(conformance.pointee.protocolDescriptor & ~1)
        let jumpPtr = UnsafeRawPointer(conformance).advanced(by: MemoryLayout<_SwiftRuntime.ProtocolConformanceDescriptor>.offset(of: \.protocolDescriptor)!).advanced(by: descriptorOffset)
        let address = jumpPtr.load(as: UInt64.self)
        
        // Address will be 0 if the protocol is not available (such as only defined on a newer OS)
        guard address != 0 else {
            return nil
        }
        let protoPtr = UnsafeRawPointer(bitPattern: UInt(address))!
        let proto = protoPtr.load(as: _SwiftRuntime.ProtocolDescriptor.self)
        let namePtr = protoPtr.advanced(by: MemoryLayout<_SwiftRuntime.ProtocolDescriptor>.offset(of: \.name)!).advanced(by: Int(proto.name))
        let protocolName = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
        /*  guard ["PreviewProvider", "PreviewRegistry"].contains(protocolName) else {
         return nil
         }*/
        
        let typeDescriptorPointer = UnsafeRawPointer(conformance).advanced(by: MemoryLayout<_SwiftRuntime.ProtocolConformanceDescriptor>.offset(of: \.nominalTypeDescriptor)!).advanced(by: Int(conformance.pointee.nominalTypeDescriptor))
        
        let descriptor = typeDescriptorPointer.assumingMemoryBound(to: _SwiftRuntime.TargetModuleContextDescriptor.self)
        if let name = getTypeName(descriptor: descriptor),
           [_SwiftRuntime.ContextDescriptorKind.Class, _SwiftRuntime.ContextDescriptorKind.Struct, _SwiftRuntime.ContextDescriptorKind.Enum].contains(descriptor.pointee.flags.kind) {
            let accessFunctionPointer = UnsafeRawPointer(descriptor).advanced(by: MemoryLayout<_SwiftRuntime.TargetModuleContextDescriptor>.offset(of: \.accessFunction)!).advanced(by: Int(descriptor.pointee.accessFunction))
            let accessFunction = unsafeBitCast(accessFunctionPointer, to: (@convention(c) () -> UInt64).self)
            return (name, accessFunction, protocolName)
        }
        return nil
    }
    
    public static func getPreviewTypes() -> [LookupResult] {
        let images = _dyld_image_count()
        var types = [LookupResult]()
        for i in 0..<images {
            let imageName = String(cString: _dyld_get_image_name(i))
            // System frameworks on the simulator are in Xcode.app/Contents/** (Although Xcode could be renamed like Xcode-beta.app so don't check for that specifically)
            guard !imageName.contains(".simruntime") && !imageName.contains(".app/Contents/") && !imageName.starts(with: "/usr/lib/") else {
                continue
            }

            let header = _dyld_get_image_header(i)!
            var size: UInt = 0
            let sectStart = UnsafeRawPointer(
                getsectiondata(
                    UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self),
                    "__TEXT",
                    "__swift5_proto",
                    &size))?.assumingMemoryBound(to: Int32.self)
            if var sectData = sectStart {
                for _ in 0..<Int(size)/MemoryLayout<Int32>.size {
                    let conformance = UnsafeRawPointer(sectData)
                        .advanced(by: Int(sectData.pointee))
                        .assumingMemoryBound(to: _SwiftRuntime.ProtocolConformanceDescriptor.self)
                    
                    if let result = parseConformance(conformance: conformance) {
                        types.append(result)
                    }
                    
                    sectData = sectData.successor()
                }
            }
        }
        return types
    }
}

