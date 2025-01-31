import WinSDK
import WinSDKExtras
import WindowsUtils

public class Sid: CustomStringConvertible {
  var value: PSID

  init(_ sid: PSID) {
    self.value = sid
  }

  static func createWellKnown(_ type: WELL_KNOWN_SID_TYPE) throws -> Sid {
    var size = DWORD(_SECURITY_MAX_SID_SIZE())
    let sid: PSID = HeapAlloc(GetProcessHeap(), DWORD(HEAP_ZERO_MEMORY), SIZE_T(size))!
    var result = CreateWellKnownSid(type, nil, sid, &size)
    guard result else {
      throw Win32Error("CreateWellKnownSid")
    }

    // Check if the SID is is of the expected type
    result = IsWellKnownSid(sid, type)
    guard result else {
      throw Win32Error("IsWellKnownSid")
    }

    return Sid(sid)
  }

  // https://github.com/googleprojectzero/sandbox-attacksurface-analysis-tools/blob/main/NtApiDotNet/SecurityCapabilities.cs#L19
  static func createSidWithCapability(_ type: String) throws -> Sid {
    let capabilityGroupSids = UnsafeMutablePointer<UnsafeMutablePointer<PSID?>?>.allocate(
      capacity: 0)
    var capabilityGroupSidsCount: DWORD = 0
    let capabilitySids = UnsafeMutablePointer<UnsafeMutablePointer<PSID?>?>.allocate(capacity: 0)
    var capabilitySidsCount: DWORD = 0

    let result = _DeriveCapabilitySidsFromName(
      type.wide,
      capabilityGroupSids,
      &capabilityGroupSidsCount,
      capabilitySids,
      &capabilitySidsCount
    )

    defer {
      // We only need to free the group SIDs, as we use the capability SIDs
      for i in 0..<Int(capabilityGroupSidsCount) {
        FreeSid(capabilityGroupSids.pointee![i])
      }
    }

    guard result, capabilitySidsCount == 1 else {
      throw Win32Error("DeriveCapabilitySidsFromName")
    }

    return Sid(capabilitySids.pointee!.pointee!)
  }

  public var description: String {
    return (try? getSidString(value)) ?? "Invalid SID"
  }

  func getSidString(_ sid: PSID) throws -> String {
    var sidString: LPWSTR? = nil

    let result = withUnsafeMutablePointer(to: &sidString) {
      ConvertSidToStringSidW(sid, $0)
    }

    guard result, let sidString = sidString else {
      throw Win32Error("ConvertSidToStringSidW")
    }

    return String(decodingCString: sidString, as: UTF16.self)
  }

  deinit {
    FreeSid(self.value)
  }
}

class SidAndAttributes {
  let sid: Sid
  let sidAttributes: SID_AND_ATTRIBUTES

  init(sid: Sid) {
    self.sid = sid
    self.sidAttributes = SID_AND_ATTRIBUTES(Sid: sid.value, Attributes: DWORD(SE_GROUP_ENABLED))
  }

  static func createWithCapability(type: SidCapability) throws -> SidAndAttributes {
    let sid =
      switch type {
      case .wellKnown(let wellKnownType):
        try Sid.createWellKnown(wellKnownType)
      case .custom(let customType):
        try Sid.createSidWithCapability(customType)
      }
    return SidAndAttributes(sid: sid)
  }
}

public enum SidCapability {
  case wellKnown(WELL_KNOWN_SID_TYPE)
  case custom(String)
}
