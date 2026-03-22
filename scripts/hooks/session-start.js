#!/usr/bin/env node
/**
 * SessionStart Hook - Load previous context on new session
 *
 * Cross-platform (Windows, macOS, Linux)
 *
 * Runs when a new Claude session starts. Loads the most recent session
 * summary into Claude's context via stdout, and reports available
 * sessions and learned skills.
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const {
  getSessionsDir,
  getLearnedSkillsDir,
  findFiles,
  ensureDir,
  readFile,
  stripAnsi,
  log,
  output
} = require('../lib/utils');
const { getPackageManager, getSelectionPrompt } = require('../lib/package-manager');
const { listAliases } = require('../lib/session-aliases');
const { detectProjectType } = require('../lib/project-detect');

async function main() {
  const sessionsDir = getSessionsDir();
  const learnedDir = getLearnedSkillsDir();

  // Ensure directories exist
  ensureDir(sessionsDir);
  ensureDir(learnedDir);

  // Check for recent session files (last 7 days)
  const recentSessions = findFiles(sessionsDir, '*-session.tmp', { maxAge: 7 });

  if (recentSessions.length > 0) {
    const latest = recentSessions[0];
    log(`[SessionStart] Found ${recentSessions.length} recent session(s)`);
    log(`[SessionStart] Latest: ${latest.path}`);

    // Read and inject the latest session content into Claude's context
    const content = stripAnsi(readFile(latest.path));
    if (content && !content.includes('[Session context goes here]')) {
      // Only inject if the session has actual content (not the blank template)
      output(`Previous session summary:\n${content}`);
    }
  }

  // Check for learned skills
  const learnedSkills = findFiles(learnedDir, '*.md');

  if (learnedSkills.length > 0) {
    log(`[SessionStart] ${learnedSkills.length} learned skill(s) available in ${learnedDir}`);
  }

  // Check for available session aliases
  const aliases = listAliases({ limit: 5 });

  if (aliases.length > 0) {
    const aliasNames = aliases.map(a => a.name).join(', ');
    log(`[SessionStart] ${aliases.length} session alias(es) available: ${aliasNames}`);
    log(`[SessionStart] Use /sessions load <alias> to continue a previous session`);
  }

  // Detect and report package manager
  const pm = getPackageManager();
  log(`[SessionStart] Package manager: ${pm.name} (${pm.source})`);

  // If no explicit package manager config was found, show selection prompt
  if (pm.source === 'default') {
    log('[SessionStart] No package manager preference found.');
    log(getSelectionPrompt());
  }

  // Load project instincts into context (#plan-5)
  try {
    const homunculus = path.join(os.homedir(), '.claude', 'homunculus');
    const registryPath = path.join(homunculus, 'projects.json');
    if (fs.existsSync(registryPath)) {
      const registry = JSON.parse(fs.readFileSync(registryPath, 'utf8'));
      const cwd = process.cwd();
      // Find matching project by root path
      const match = Object.values(registry).find(p => cwd.startsWith(p.root));
      if (match) {
        const instinctsDir = path.join(homunculus, 'projects', match.id, 'instincts', 'personal');
        if (fs.existsSync(instinctsDir)) {
          const instinctFiles = fs.readdirSync(instinctsDir).filter(f => f.endsWith('.md'));
          if (instinctFiles.length > 0) {
            const instincts = instinctFiles.slice(0, 10).map(f => {
              const content = fs.readFileSync(path.join(instinctsDir, f), 'utf8');
              // Extract id and action from frontmatter and body
              const idMatch = content.match(/^id:\s*(.+)$/m);
              const actionMatch = content.match(/## Action\s*\n(.+)/);
              const triggerMatch = content.match(/^trigger:\s*(.+)$/m);
              if (idMatch && actionMatch) {
                return `- ${triggerMatch ? triggerMatch[1] : idMatch[1]}: ${actionMatch[1].trim()}`;
              }
              return null;
            }).filter(Boolean);
            if (instincts.length > 0) {
              output(`Project instincts (${match.name}):\n${instincts.join('\n')}`);
              log(`[SessionStart] Loaded ${instincts.length} instinct(s) for ${match.name}`);
            }
          }
        }
      }
    }
  } catch (err) {
    log(`[SessionStart] Instinct loading skipped: ${err.message}`);
  }

  // Auto-start instinct observer if observations exceed threshold (#plan-1)
  try {
    const homunculus = path.join(os.homedir(), '.claude', 'homunculus', 'projects');
    if (fs.existsSync(homunculus)) {
      const projectDirs = fs.readdirSync(homunculus, { withFileTypes: true })
        .filter(d => d.isDirectory());
      for (const dir of projectDirs) {
        const projPath = path.join(homunculus, dir.name);
        const obsFile = path.join(projPath, 'observations.jsonl');
        const pidFile = path.join(projPath, '.observer.pid');
        if (fs.existsSync(obsFile) && !fs.existsSync(pidFile)) {
          const lineCount = fs.readFileSync(obsFile, 'utf8').split('\n').filter(Boolean).length;
          if (lineCount >= 50) {
            log(`[SessionStart] ${lineCount} unprocessed observations in ${dir.name}, consider running: bash ~/.claude/skills/continuous-learning-v2/agents/start-observer.sh`);
          }
        }
      }
    }
  } catch (err) {
    log(`[SessionStart] Observer check skipped: ${err.message}`);
  }

  // Detect project type and frameworks (#293)
  const projectInfo = detectProjectType();
  if (projectInfo.languages.length > 0 || projectInfo.frameworks.length > 0) {
    const parts = [];
    if (projectInfo.languages.length > 0) {
      parts.push(`languages: ${projectInfo.languages.join(', ')}`);
    }
    if (projectInfo.frameworks.length > 0) {
      parts.push(`frameworks: ${projectInfo.frameworks.join(', ')}`);
    }
    log(`[SessionStart] Project detected — ${parts.join('; ')}`);
    output(`Project type: ${JSON.stringify(projectInfo)}`);
  } else {
    log('[SessionStart] No specific project type detected');
  }

  process.exit(0);
}

main().catch(err => {
  console.error('[SessionStart] Error:', err.message);
  process.exit(0); // Don't block on errors
});
