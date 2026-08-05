const std = @import("std");

pub const TokenType = enum {
    // Literals
    number_literal,
    string_literal,
    identifier,

    // Keywords
    keyword_and,
    keyword_break,
    keyword_do,
    keyword_else,
    keyword_elseif,
    keyword_end,
    keyword_false,
    keyword_for,
    keyword_function,
    keyword_if,
    keyword_in,
    keyword_local,
    keyword_nil,
    keyword_not,
    keyword_or,
    keyword_repeat,
    keyword_return,
    keyword_then,
    keyword_true,
    keyword_until,
    keyword_while,

    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    caret,
    hash,
    ampersand,
    tilde,
    pipe,
    less_than,
    greater_than,
    less_equal,
    greater_equal,
    equal_equal,
    not_equal,
    assign,
    left_paren,
    right_paren,
    left_bracket,
    right_bracket,
    left_brace,
    right_brace,
    dot,
    dot_dot,
    dot_dot_dot,
    comma,
    colon,
    semicolon,

    // Special
    newline,
    eof,
    error_token,
};

pub const Token = struct {
    type: TokenType,
    start: usize,
    length: usize,
    line: usize,
};

pub const Lexer = struct {
    source: []const u8,
    position: usize,
    line: usize,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .position = 0,
            .line = 1,
        };
    }

    fn peek(self: *Lexer) u8 {
        if (self.position >= self.source.len) return 0;
        return self.source[self.position];
    }

    fn peekNext(self: *Lexer) u8 {
        if (self.position + 1 >= self.source.len) return 0;
        return self.source[self.position + 1];
    }

    fn advance(self: *Lexer) u8 {
        const ch = self.peek();
        self.position += 1;
        if (ch == '\n') self.line += 1;
        return ch;
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.position < self.source.len) {
            const ch = self.peek();
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                self.position += 1;
            } else if (ch == '\n') {
                self.position += 1;
                self.line += 1;
            } else if (ch == '-' and self.peekNext() == '-') {
                // Single-line comment
                self.position += 2;
                while (self.position < self.source.len and self.peek() != '\n') {
                    self.position += 1;
                }
            } else if (ch == '[' and self.peekNext() == '[') {
                // Long comment or long string - skip for now
                break;
            } else {
                break;
            }
        }
    }

    fn makeToken(self: *Lexer, ttype: TokenType, start: usize, length: usize) Token {
        return .{
            .type = ttype,
            .start = start,
            .length = length,
            .line = self.line,
        };
    }

    fn readNumber(self: *Lexer) Token {
        const start = self.position;
        while (self.position < self.source.len) {
            const ch = self.peek();
            if (ch >= '0' and ch <= '9') {
                self.position += 1;
            } else if (ch == '.') {
                self.position += 1;
                while (self.position < self.source.len and self.peek() >= '0' and self.peek() <= '9') {
                    self.position += 1;
                }
                break;
            } else {
                break;
            }
        }
        return self.makeToken(.number_literal, start, self.position - start);
    }

    fn readString(self: *Lexer, quote: u8) Token {
        const start = self.position + 1; // skip opening quote
        self.position += 1;
        while (self.position < self.source.len) {
            const ch = self.peek();
            if (ch == quote) {
                self.position += 1;
                return self.makeToken(.string_literal, start, self.position - start - 1);
            } else if (ch == '\\') {
                self.position += 2;
            } else if (ch == '\n') {
                self.line += 1;
                self.position += 1;
            } else {
                self.position += 1;
            }
        }
        return self.makeToken(.error_token, start, 0);
    }

    fn readIdentifier(self: *Lexer) Token {
        const start = self.position;
        while (self.position < self.source.len) {
            const ch = self.peek();
            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_') {
                self.position += 1;
            } else {
                break;
            }
        }
        const word = self.source[start..self.position];
        const ttype = keywordLookup(word);
        return self.makeToken(ttype, start, self.position - start);
    }

    fn keywordLookup(word: []const u8) TokenType {
        const Keyword = struct { name: []const u8, token: TokenType };
        const keywords = [_]Keyword{
            .{ .name = "and", .token = .keyword_and },
            .{ .name = "break", .token = .keyword_break },
            .{ .name = "do", .token = .keyword_do },
            .{ .name = "else", .token = .keyword_else },
            .{ .name = "elseif", .token = .keyword_elseif },
            .{ .name = "end", .token = .keyword_end },
            .{ .name = "false", .token = .keyword_false },
            .{ .name = "for", .token = .keyword_for },
            .{ .name = "function", .token = .keyword_function },
            .{ .name = "if", .token = .keyword_if },
            .{ .name = "in", .token = .keyword_in },
            .{ .name = "local", .token = .keyword_local },
            .{ .name = "nil", .token = .keyword_nil },
            .{ .name = "not", .token = .keyword_not },
            .{ .name = "or", .token = .keyword_or },
            .{ .name = "repeat", .token = .keyword_repeat },
            .{ .name = "return", .token = .keyword_return },
            .{ .name = "then", .token = .keyword_then },
            .{ .name = "true", .token = .keyword_true },
            .{ .name = "until", .token = .keyword_until },
            .{ .name = "while", .token = .keyword_while },
        };
        for (keywords) |kw| {
            if (std.mem.eql(u8, word, kw.name)) return kw.token;
        }
        return .identifier;
    }

    pub fn nextToken(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.position >= self.source.len) {
            return self.makeToken(.eof, self.position, 0);
        }

        const start = self.position;
        const ch = self.advance();

        if (ch >= '0' and ch <= '9') return self.readNumber();
        if (ch == '"' or ch == '\'') return self.readString(ch);
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_') return self.readIdentifier();

        return switch (ch) {
            '+' => self.makeToken(.plus, start, 1),
            '-' => self.makeToken(.minus, start, 1),
            '*' => self.makeToken(.star, start, 1),
            '/' => self.makeToken(.slash, start, 1),
            '%' => self.makeToken(.percent, start, 1),
            '^' => self.makeToken(.caret, start, 1),
            '#' => self.makeToken(.hash, start, 1),
            '&' => self.makeToken(.ampersand, start, 1),
            '~' => {
                if (self.peek() == '=') {
                    self.position += 1;
                    return self.makeToken(.not_equal, start, 2);
                }
                return self.makeToken(.tilde, start, 1);
            },
            '|' => self.makeToken(.pipe, start, 1),
            '<' => {
                if (self.peek() == '=') {
                    self.position += 1;
                    return self.makeToken(.less_equal, start, 2);
                }
                return self.makeToken(.less_than, start, 1);
            },
            '>' => {
                if (self.peek() == '=') {
                    self.position += 1;
                    return self.makeToken(.greater_equal, start, 2);
                }
                return self.makeToken(.greater_than, start, 1);
            },
            '=' => {
                if (self.peek() == '=') {
                    self.position += 1;
                    return self.makeToken(.equal_equal, start, 2);
                }
                return self.makeToken(.assign, start, 1);
            },
            '(' => self.makeToken(.left_paren, start, 1),
            ')' => self.makeToken(.right_paren, start, 1),
            '[' => self.makeToken(.left_bracket, start, 1),
            ']' => self.makeToken(.right_bracket, start, 1),
            '{' => self.makeToken(.left_brace, start, 1),
            '}' => self.makeToken(.right_brace, start, 1),
            '.' => {
                if (self.peek() == '.') {
                    self.position += 1;
                    if (self.peek() == '.') {
                        self.position += 1;
                        return self.makeToken(.dot_dot_dot, start, 3);
                    }
                    return self.makeToken(.dot_dot, start, 2);
                }
                return self.makeToken(.dot, start, 1);
            },
            ',' => self.makeToken(.comma, start, 1),
            ':' => self.makeToken(.colon, start, 1),
            ';' => self.makeToken(.semicolon, start, 1),
            '\n' => self.makeToken(.newline, start, 1),
            else => self.makeToken(.error_token, start, 1),
        };
    }

    pub fn getTokenText(self: *Lexer, token: Token) []const u8 {
        return if (token.start + token.length <= self.source.len)
            self.source[token.start .. token.start + token.length]
        else
            "";
    }
};
