//
//  YouTubeMusicAuthentication.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-14.
//

import Foundation

// MARK: - 认证管理器
actor YouTubeMusicAuthManager {
    private var accessToken: String?
    private var authenticationTask: Task<String, Error>?
    private let httpClient: YouTubeMusicHTTPClient
    
    init(httpClient: YouTubeMusicHTTPClient) {
        self.httpClient = httpClient
    }
    
    var currentToken: String? {
        accessToken
    }
    
    func authenticate() async throws -> String {
        // 若已有有效令牌则直接返回
        if let token = accessToken {
            return token
        }
        
        // 若已有认证正在进行则等待其结果
        if let task = authenticationTask {
            return try await task.value
        }
        
        // 开始新的认证
        let task = Task<String, Error> {
            do {
                let token = try await httpClient.authenticate()
                await setToken(token)
                return token
            } catch {
                await clearAuthenticationTask()
                throw error
            }
        }
        
        authenticationTask = task
        return try await task.value
    }
    
    func invalidateToken() async {
        accessToken = nil
        authenticationTask?.cancel()
        authenticationTask = nil
    }
    
    private func setToken(_ token: String) async {
        accessToken = token
        authenticationTask = nil
    }
    
    private func clearAuthenticationTask() async {
        authenticationTask = nil
    }
}

// MARK: - 认证状态
enum AuthenticationState: Sendable {
    case unauthenticated
    case authenticating
    case authenticated(String)
    case failed(Error)
    
    var isAuthenticated: Bool {
        if case .authenticated = self {
            return true
        }
        return false
    }
    
    var token: String? {
        if case .authenticated(let token) = self {
            return token
        }
        return nil
    }
}