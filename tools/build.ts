import * as fs from 'fs';
import * as path from 'path';

const SRC_DIR = path.join(__dirname, '../src');
const MAIN_FILE = path.join(__dirname, '../Main.local.lua');

function getAllFiles(dirPath: string, arrayOfFiles: string[] = []) {
    const files = fs.readdirSync(dirPath);

    files.forEach((file) => {
        const fullPath = path.join(dirPath, file);
        if (fs.statSync(fullPath).isDirectory()) {
            arrayOfFiles = getAllFiles(fullPath, arrayOfFiles);
        } else if (fullPath.endsWith('.lua')) {
            arrayOfFiles.push(fullPath);
        }
    });

    return arrayOfFiles;
}

function build() {
    const luaFiles = getAllFiles(SRC_DIR);
    const modules: Record<string, string> = {};

    for (const file of luaFiles) {
        const basename = path.basename(file, '.lua');
        const content = fs.readFileSync(file, 'utf8');
        modules[basename] = content;
        console.log(`- Included ${basename}`);
    }

    let mainContent = fs.readFileSync(MAIN_FILE, 'utf8');

    const startPattern = 'local moduleSources: { [string]: string } = {';
    const startIndex = mainContent.indexOf(startPattern);
    
    if (startIndex === -1) {
        throw new Error('Could not find moduleSources declaration in Main.local.lua');
    }

    const endPattern = '\n}';
    let currentIndex = startIndex + startPattern.length;
    let endIndex = -1;
    let inStringContext = false;
    
    for (let i = currentIndex; i < mainContent.length; i++) {
        if (mainContent.substring(i, i + 5) === '[===[') {
            inStringContext = true;
            i += 4;
            continue;
        }
        if (mainContent.substring(i, i + 5) === ']===]') {
            inStringContext = false;
            i += 4;
            continue;
        }
        if (!inStringContext && mainContent.substring(i, i + 2) === '\n}') {
            endIndex = i + 2;
            break;
        }
    }

    if (endIndex === -1) {
        throw new Error('Could not find the end of moduleSources block');
    }

    let nextBlock = '\n';
    for (const [name, source] of Object.entries(modules)) {
        nextBlock += `\t${name} = [===[\n${source}\n]===],\n`;
    }
    nextBlock += '}';

    mainContent = mainContent.substring(0, startIndex + startPattern.length) + nextBlock + mainContent.substring(endIndex);

    fs.writeFileSync(MAIN_FILE, mainContent, 'utf8');
}

build();
