/*
ShaderGlass: shader effect overlay
Copyright (C) 2021-2025 mausimus (mausimus.net)
https://github.com/mausimus/ShaderGlass
GNU General Public License v3.0
*/

#include "pch.h"

#include "resource.h"
#include "ParamsWindow.h"

constexpr int STATIC_WIDTH  = 300;
constexpr int STATIC_HEIGHT = 40;
constexpr int BUTTON_WIDTH  = 100;
constexpr int BUTTON_HEIGHT = 25;
constexpr int BUTTON_TOP    = 20;
constexpr int PARAMS_TOP    = 75;
constexpr int PARAM_HEIGHT  = 40;
constexpr int WINDOW_WIDTH  = 670;
constexpr int WINDOW_HEIGHT = 600;
constexpr int TRACK_WIDTH   = 200;
constexpr int TRACK_HEIGHT  = 30;
constexpr int TOOLTIP_MAX_WIDTH = 420;
constexpr int VIEW_TOGGLE_WIDTH = 155;
constexpr int VIEW_TOGGLE_HEIGHT = 25;
constexpr int VIEW_TOGGLE_LEFT = 10;
constexpr int VIEW_TOGGLE_TOP = 20;
constexpr int TOP_CONTROL_GAP = 10;
constexpr int ID_VIEWMODE_TOGGLE = 50001;

namespace
{
LRESULT CALLBACK TrackbarSubclassProc(HWND hWnd, UINT message, WPARAM wParam, LPARAM lParam, UINT_PTR, DWORD_PTR)
{
    if(message == WM_MOUSEWHEEL || message == WM_MOUSEHWHEEL)
    {
        HWND parent = GetParent(hWnd);
        if(parent)
        {
            SendMessage(parent, WM_MOUSEWHEEL, wParam, lParam);
        }
        return 0;
    }

    return DefSubclassProc(hWnd, message, wParam, lParam);
}

std::string TrimCopy(const std::string& value)
{
    size_t start = value.find_first_not_of(" \t");
    if(start == std::string::npos)
    {
        return "";
    }

    size_t end = value.find_last_not_of(" \t");
    return value.substr(start, end - start + 1);
}

struct StateLabelText
{
    std::string leftLabel;
    std::vector<std::string> stateLabels;
};

struct DisplayTextParts
{
    std::string label;
    std::string tooltipPrefix;
};

DisplayTextParts ParseDisplayTextParts(const char* rawText)
{
    std::string text = rawText ? rawText : "";

    DisplayTextParts output;
    output.label = text;

    size_t separator = text.find("||");
    if(separator == std::string::npos)
    {
        return output;
    }

    std::string labelPart   = TrimCopy(text.substr(0, separator));
    std::string tooltipPart = TrimCopy(text.substr(separator + 2));

    if(!labelPart.empty())
    {
        output.label = labelPart;
    }
    if(!tooltipPart.empty())
    {
        output.tooltipPrefix = tooltipPart;
    }

    return output;
}

StateLabelText ParseStateLabelText(const char* rawLabel)
{
    std::string label = rawLabel ? rawLabel : "";

    StateLabelText output;
    output.leftLabel = label;

    size_t openParen = label.rfind('(');
    size_t closeParen = label.rfind(')');
    if(openParen == std::string::npos || closeParen == std::string::npos || openParen >= closeParen)
    {
        return output;
    }

    std::string inside = TrimCopy(label.substr(openParen + 1, closeParen - openParen - 1));
    std::vector<std::string> labels;
    size_t start = 0;
    while(start < inside.size())
    {
        size_t slash = inside.find('/', start);
        std::string token = TrimCopy(inside.substr(start, slash == std::string::npos ? std::string::npos : slash - start));
        if(!token.empty())
        {
            labels.push_back(token);
        }
        if(slash == std::string::npos)
        {
            break;
        }
        start = slash + 1;
    }

    std::string leftLabel = TrimCopy(label.substr(0, openParen));

    if(leftLabel.empty() || labels.size() < 2)
    {
        return output;
    }

    output.leftLabel = leftLabel;
    output.stateLabels = labels;
    return output;
}

int GetStepPrecision(float step)
{
    if(step <= 0.0f)
    {
        return 3;
    }

    char stepBuffer[64] = {};
    snprintf(stepBuffer, sizeof(stepBuffer), "%.6f", step);
    std::string stepText(stepBuffer);

    while(!stepText.empty() && stepText.back() == '0')
    {
        stepText.pop_back();
    }
    if(!stepText.empty() && stepText.back() == '.')
    {
        stepText.pop_back();
    }

    auto dot = stepText.find('.');
    if(dot == std::string::npos)
    {
        return 0;
    }

    return (int)(stepText.size() - dot - 1);
}

std::string FormatNumericValue(float value, int precision)
{
    if(fabsf(value) < 0.000001f)
    {
        value = 0.0f;
    }

    char valueBuffer[64] = {};
    if(precision <= 0)
    {
        snprintf(valueBuffer, sizeof(valueBuffer), "%.0f", value);
    }
    else
    {
        snprintf(valueBuffer, sizeof(valueBuffer), "%.*f", precision, value);
    }

    return valueBuffer;
}
} // namespace

ParamsWindow::ParamsWindow(CaptureManager& captureManager) :
    m_captureManager(captureManager), m_captureOptions(captureManager.m_options), m_title(), m_windowClass(), m_resetButtonWnd(0), m_closeButtonWnd(0), m_viewModeToggleWnd(0), m_font(0), m_dpiScale(1.0f),
    m_hwndTip(NULL)
{ }

LRESULT CALLBACK ParamsWindow::WndProcProxy(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    ParamsWindow* app;
    if(msg == WM_CREATE)
    {
        app = (ParamsWindow*)(((LPCREATESTRUCT)lParam)->lpCreateParams);
        SetWindowLongPtr(hWnd, GWLP_USERDATA, (LONG_PTR)app);
    }
    else
    {
        app = (ParamsWindow*)GetWindowLongPtr(hWnd, GWLP_USERDATA);
    }
    return app->WndProc(hWnd, msg, wParam, lParam);
}

ATOM ParamsWindow::MyRegisterClass(HINSTANCE hInstance)
{
    WNDCLASSEXW wcex;

    wcex.cbSize = sizeof(WNDCLASSEX);

    wcex.style         = CS_HREDRAW | CS_VREDRAW;
    wcex.lpfnWndProc   = ParamsWindow::WndProcProxy;
    wcex.cbClsExtra    = 0;
    wcex.cbWndExtra    = 0;
    wcex.hInstance     = hInstance;
    wcex.hIcon         = LoadIcon(hInstance, MAKEINTRESOURCE(IDI_SHADERGLASS));
    wcex.hCursor       = LoadCursor(nullptr, IDC_ARROW);
    wcex.hbrBackground = (HBRUSH)GetSysColorBrush(COLOR_MENU);
    wcex.lpszMenuName  = 0;
    wcex.lpszClassName = m_windowClass;
    wcex.hIconSm       = LoadIcon(wcex.hInstance, MAKEINTRESOURCE(IDI_SMALL));

    return RegisterClassExW(&wcex);
}

BOOL ParamsWindow::InitInstance(HINSTANCE hInstance, int nCmdShow)
{
    m_instance = hInstance;

    RECT rect;
    rect.left   = 0;
    rect.top    = 0;
    rect.right  = (LONG)(WINDOW_WIDTH);
    rect.bottom = (LONG)(WINDOW_HEIGHT);
    AdjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, true, WS_EX_WINDOWEDGE);

    HWND hWnd = CreateWindowW(m_windowClass,
                              m_title,
                              WS_OVERLAPPEDWINDOW | WS_EX_WINDOWEDGE | WS_VSCROLL,
                              CW_USEDEFAULT,
                              CW_USEDEFAULT,
                              rect.right - rect.left,
                              rect.bottom - rect.top,
                              m_shaderWindow,
                              nullptr,
                              hInstance,
                              this);

    if(!hWnd)
    {
        return FALSE;
    }

    m_dpi      = GetDpiForWindow(hWnd);
    m_dpiScale = m_dpi / (float)USER_DEFAULT_SCREEN_DPI;
    if(m_dpi != USER_DEFAULT_SCREEN_DPI)
    {
        rect.right *= m_dpiScale;
        rect.bottom *= m_dpiScale;
        SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, rect.right - rect.left, rect.bottom - rect.top, SWP_NOMOVE);
    }

    NONCLIENTMETRICS metrics = {};
    metrics.cbSize           = sizeof(metrics);
    SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, metrics.cbSize, &metrics, 0, m_dpi);
    m_font = CreateFontIndirect(&metrics.lfCaptionFont);

    m_mainWindow = hWnd;

    m_viewModeToggleWnd = CreateWindow(L"BUTTON",
                                       L"Nice view",
                                       WS_TABSTOP | WS_VISIBLE | WS_CHILD | BS_AUTOCHECKBOX,
                                       (LONG)(m_dpiScale * VIEW_TOGGLE_LEFT),
                                       (LONG)(m_dpiScale * VIEW_TOGGLE_TOP),
                                       (LONG)(m_dpiScale * VIEW_TOGGLE_WIDTH),
                                       (LONG)(m_dpiScale * VIEW_TOGGLE_HEIGHT),
                                       m_mainWindow,
                                       (HMENU)ID_VIEWMODE_TOGGLE,
                                       (HINSTANCE)GetWindowLongPtr(m_mainWindow, GWLP_HINSTANCE),
                                       NULL);
    SendMessage(m_viewModeToggleWnd, WM_SETFONT, (LPARAM)m_font, true);
    SendMessage(m_viewModeToggleWnd, BM_SETCHECK, m_useNiceView ? BST_CHECKED : BST_UNCHECKED, 0);

    m_resetButtonWnd = CreateWindow(L"BUTTON",
                                    L"Defaults",
                                    WS_TABSTOP | WS_VISIBLE | WS_CHILD,
                                    (LONG)(m_dpiScale * ((WINDOW_WIDTH / 3) - (BUTTON_WIDTH / 2))),
                                    (LONG)(m_dpiScale * BUTTON_TOP),
                                    (LONG)(m_dpiScale * BUTTON_WIDTH),
                                    (LONG)(m_dpiScale * BUTTON_HEIGHT),
                                    m_mainWindow,
                                    NULL,
                                    (HINSTANCE)GetWindowLongPtr(m_mainWindow, GWLP_HINSTANCE),
                                    NULL);
    SendMessage(m_resetButtonWnd, WM_SETFONT, (LPARAM)m_font, true);

    m_closeButtonWnd = CreateWindow(L"BUTTON",
                                    L"Close",
                                    WS_TABSTOP | WS_VISIBLE | WS_CHILD | BS_DEFPUSHBUTTON,
                                    (LONG)(m_dpiScale * ((2 * WINDOW_WIDTH / 3) - (BUTTON_WIDTH / 2))),
                                    (LONG)(m_dpiScale * BUTTON_TOP),
                                    (LONG)(m_dpiScale * BUTTON_WIDTH),
                                    (LONG)(m_dpiScale * BUTTON_HEIGHT),
                                    m_mainWindow,
                                    NULL,
                                    (HINSTANCE)GetWindowLongPtr(m_mainWindow, GWLP_HINSTANCE),
                                    NULL);
    SendMessage(m_closeButtonWnd, WM_SETFONT, (LPARAM)m_font, true);

    ShowWindow(hWnd, nCmdShow);
    UpdateWindow(hWnd);

    SetWindowPos(m_mainWindow, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);

    return TRUE;
}

void ParamsWindow::Resize()
{
    auto dpi = GetDpiForWindow(m_mainWindow);
    if(dpi != m_dpi)
    {
        m_dpi      = dpi;
        m_dpiScale = dpi / (float)USER_DEFAULT_SCREEN_DPI;

        // resize fonts
        NONCLIENTMETRICS metrics = {};
        metrics.cbSize           = sizeof(metrics);
        SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, metrics.cbSize, &metrics, 0, m_dpi);
        DeleteObject(m_font);
        m_font = CreateFontIndirect(&metrics.lfCaptionFont);
        
        SendMessage(m_resetButtonWnd, WM_SETFONT, (WPARAM)m_font, MAKELPARAM(TRUE, 0));
        SendMessage(m_closeButtonWnd, WM_SETFONT, (WPARAM)m_font, MAKELPARAM(TRUE, 0));
        SendMessage(m_viewModeToggleWnd, WM_SETFONT, (WPARAM)m_font, MAKELPARAM(TRUE, 0));

        RebuildControls(false);
    }

    RECT rect;
    GetClientRect(m_mainWindow, &rect);

    SCROLLINFO si;
    si.cbSize = sizeof(si);
    si.fMask  = SIF_ALL;
    GetScrollInfo(m_mainWindow, SB_VERT, &si);

    // calculate
    auto actualSize   = rect.bottom - rect.top;
    auto requiredSize = m_dpiScale * ((m_trackbars.size() + 0) * PARAM_HEIGHT + PARAMS_TOP);

    if(requiredSize < actualSize)
    {
        ScrollWindow(m_mainWindow, 0, 5 * si.nPos, NULL, NULL);
        si.nMin = 0;
        si.nMax = 0;
        si.nPos = 0;
        SetScrollInfo(m_mainWindow, SB_VERT, &si, true);
        EnableScrollBar(m_mainWindow, SB_VERT, ESB_DISABLE_BOTH);
    }
    else
    {
        EnableScrollBar(m_mainWindow, SB_VERT, ESB_ENABLE_BOTH);
        ScrollWindow(m_mainWindow, 0, 5 * si.nPos, NULL, NULL);
        si.nMin = 0;
        si.nMax = (int)((requiredSize - actualSize) / 5);
        si.nPos = 0;
        SetScrollInfo(m_mainWindow, SB_VERT, &si, true);
    }

    const LONG topLeft   = (LONG)(m_dpiScale * VIEW_TOGGLE_LEFT);
    const LONG topY      = (LONG)(m_dpiScale * BUTTON_TOP);
    const LONG gap       = (LONG)(m_dpiScale * TOP_CONTROL_GAP);
    const LONG buttonW   = (LONG)(m_dpiScale * BUTTON_WIDTH);
    const LONG buttonH   = (LONG)(m_dpiScale * BUTTON_HEIGHT);
    const LONG toggleW   = (LONG)(m_dpiScale * VIEW_TOGGLE_WIDTH);
    const LONG toggleH   = (LONG)(m_dpiScale * VIEW_TOGGLE_HEIGHT);

    LONG x = topLeft;
    if(!m_trackbars.empty())
    {
        SetWindowPos(m_resetButtonWnd, NULL, x, topY, buttonW, buttonH, SWP_NOZORDER | SWP_NOACTIVATE);
        x += buttonW + gap;
    }

    SetWindowPos(m_closeButtonWnd, NULL, x, topY, buttonW, buttonH, SWP_NOZORDER | SWP_NOACTIVATE);
    x += buttonW + gap;

    SetWindowPos(m_viewModeToggleWnd, NULL, x, (LONG)(m_dpiScale * VIEW_TOGGLE_TOP), toggleW, toggleH, SWP_NOZORDER | SWP_NOACTIVATE);

    for(size_t i = 0; i < m_trackbars.size(); ++i)
    {
        LayoutTrackbarControl(m_trackbars[i], i, si.nPos);
    }
}

void ParamsWindow::LayoutTrackbarControl(ParamsTrackbar& trackbar, size_t index, int scrollPos)
{
    RECT rect = {};
    GetClientRect(m_mainWindow, &rect);

    const LONG clientWidth = (std::max)(1L, rect.right - rect.left);
    const LONG margin      = (LONG)(m_dpiScale * 6.0f);
    const LONG gap         = (LONG)(m_dpiScale * 8.0f);

    LONG usableWidth = clientWidth - margin * 2 - gap * 2;
    if(usableWidth < 3)
    {
        usableWidth = 3;
    }

    LONG labelWidth  = (LONG)roundf(usableWidth * 0.5f);
    LONG sliderWidth = (LONG)roundf(usableWidth * 0.3f);
    LONG valueWidth  = usableWidth - labelWidth - sliderWidth;

    const LONG minLabelWidth  = (LONG)(m_dpiScale * 120.0f);
    const LONG minSliderWidth = (LONG)(m_dpiScale * 90.0f);
    const LONG minValueWidth  = (LONG)(m_dpiScale * 70.0f);
    const LONG minTotalWidth  = minLabelWidth + minSliderWidth + minValueWidth;

    if(usableWidth >= minTotalWidth)
    {
        labelWidth  = (std::max)(labelWidth, minLabelWidth);
        sliderWidth = (std::max)(sliderWidth, minSliderWidth);
        valueWidth  = usableWidth - labelWidth - sliderWidth;

        if(valueWidth < minValueWidth)
        {
            LONG deficit = minValueWidth - valueWidth;

            LONG steal = (std::min)(deficit, labelWidth - minLabelWidth);
            labelWidth -= steal;
            deficit -= steal;

            steal = (std::min)(deficit, sliderWidth - minSliderWidth);
            sliderWidth -= steal;
            deficit -= steal;

            valueWidth = usableWidth - labelWidth - sliderWidth;
        }
    }

    if(labelWidth < 1)
        labelWidth = 1;
    if(sliderWidth < 1)
        sliderWidth = 1;
    valueWidth = usableWidth - labelWidth - sliderWidth;
    if(valueWidth < 1)
    {
        valueWidth = 1;
        if(sliderWidth > 1)
        {
            --sliderWidth;
        }
        else if(labelWidth > 1)
        {
            --labelWidth;
        }
    }

    const LONG rowTop      = (LONG)(m_dpiScale * (index * PARAM_HEIGHT + PARAMS_TOP)) - (LONG)(scrollPos * 5);
    const LONG rowHeight   = (LONG)(m_dpiScale * PARAM_HEIGHT);
    const LONG labelHeight = (LONG)(m_dpiScale * STATIC_HEIGHT);
    const LONG valueHeight = (LONG)(m_dpiScale * STATIC_HEIGHT);
    const LONG sliderHeight = (LONG)(m_dpiScale * TRACK_HEIGHT);

    const LONG labelLeft  = margin;
    const LONG sliderLeft = labelLeft + labelWidth + gap;
    const LONG valueLeft  = sliderLeft + sliderWidth + gap;

    SetWindowPos(trackbar.paramNameWnd, NULL, labelLeft, rowTop, labelWidth, labelHeight, SWP_NOZORDER | SWP_NOACTIVATE);
    SetWindowPos(trackbar.trackBarWnd,
                 NULL,
                 sliderLeft,
                 rowTop + (rowHeight - sliderHeight) / 2,
                 sliderWidth,
                 sliderHeight,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    SetWindowPos(trackbar.paramValueWnd, NULL, valueLeft, rowTop, valueWidth, valueHeight, SWP_NOZORDER | SWP_NOACTIVATE);
}

void ParamsWindow::RebuildControls(bool doResize)
{
    for(auto& t : m_trackbars)
    {
        if(t.paramNameWnd)
            DestroyWindow(t.paramNameWnd);
        if(t.paramValueWnd)
            DestroyWindow(t.paramValueWnd);
        if(t.trackBarWnd)
            DestroyWindow(t.trackBarWnd);
    }
    if(m_hwndTip)
    {
        DestroyWindow(m_hwndTip);
    }
    m_trackbars.clear();

    SCROLLINFO si;
    si.cbSize = sizeof(si);
    si.fMask  = SIF_ALL;
    GetScrollInfo(m_mainWindow, SB_VERT, &si);
    if(si.nPos != 0 && doResize)
    {
        Resize();
    }

    char        title[200];
    const auto& shader = m_captureManager.Presets().at(m_captureOptions.presetNo);
    if(m_captureManager.IsActive())
        snprintf(title, 200, "Shader Parameters: %s", shader->Name.c_str());
    else
        snprintf(title, 200, "Shader Parameters");
    SetWindowTextA(m_mainWindow, title);

    m_hwndTip = CreateWindowEx(NULL,
                               TOOLTIPS_CLASS,
                               NULL,
                               WS_POPUP | TTS_NOANIMATE | TTS_NOFADE | TTS_NOPREFIX,
                               CW_USEDEFAULT,
                               CW_USEDEFAULT,
                               CW_USEDEFAULT,
                               CW_USEDEFAULT,
                               m_mainWindow,
                               NULL,
                               m_instance,
                               NULL);
    if(m_hwndTip)
    {
        const int maxTooltipWidth = (std::max)(1, (int)std::lround(m_dpiScale * TOOLTIP_MAX_WIDTH));
        SendMessage(m_hwndTip, TTM_SETMAXTIPWIDTH, 0, maxTooltipWidth);
    }

    for(const auto& pt : m_captureManager.Params())
    {
        const auto& p = std::get<1>(pt);
        if(p->maxValue != p->minValue)
        {
            int numSteps = 10;
            if(p->stepValue > 0.0f)
            {
                numSteps = (int)roundf((p->maxValue - p->minValue) / p->stepValue);
            }
            if(numSteps < 1)
            {
                numSteps = 1;
            }
            int startValue = (int)roundf(numSteps * (p->currentValue - p->minValue) / (p->maxValue - p->minValue));
            startValue     = (std::max)(0, (std::min)(startValue, numSteps));

            AddTrackbar(0, numSteps, startValue, numSteps, p->name.c_str(), p);
        }
    }

    if(m_trackbars.size())
        ShowWindow(m_resetButtonWnd, SW_SHOWNA);
    else
        ShowWindow(m_resetButtonWnd, SW_HIDE);

    if(doResize)
        Resize();
}

LRESULT CALLBACK ParamsWindow::WndProc(HWND hWnd, UINT message, WPARAM wParam, LPARAM lParam)
{
    switch(message)
    {
    case WM_SHOWWINDOW: {
        if(wParam)
        {
            // showing
            if(m_captureManager.IsActive())
            {
                RebuildControls(true);
            }
            else
            {
                Resize();
            }
        }
        break;
    }
    case WM_KEYDOWN: {
        if(wParam == VK_ESCAPE)
        {
            ShowWindow(m_mainWindow, SW_HIDE);
            return 1;
        }
        break;
    }
    case WM_CLOSE: {
        ShowWindow(hWnd, SW_HIDE);
        return 0;
    }
    case WM_SIZE: {
        Resize();
        break;
    }
    case WM_MOUSEWHEEL:
    case WM_VSCROLL: {
        SCROLLINFO si;
        si.cbSize = sizeof(si);
        si.fMask  = SIF_ALL;
        GetScrollInfo(hWnd, SB_VERT, &si);

        int yPos = si.nPos;
        if(message == WM_MOUSEWHEEL)
        {
            si.nPos -= PARAM_HEIGHT * GET_WHEEL_DELTA_WPARAM(wParam) / 120 / 4;
        }
        else
            switch(LOWORD(wParam))
            {
            case SB_TOP:
                si.nPos = si.nMin;
                break;
            case SB_BOTTOM:
                si.nPos = si.nMax;
                break;
            case SB_LINEUP:
                si.nPos -= 1;
                break;
            case SB_LINEDOWN:
                si.nPos += 1;
                break;
            case SB_PAGEUP:
                si.nPos -= si.nPage;
                break;
            case SB_PAGEDOWN:
                si.nPos += si.nPage;
                break;
            case SB_THUMBTRACK:
                si.nPos = si.nTrackPos;
                break;
            default:
                break;
            }

        si.fMask = SIF_POS;
        SetScrollInfo(hWnd, SB_VERT, &si, TRUE);
        GetScrollInfo(hWnd, SB_VERT, &si);

        if(si.nPos != yPos)
        {
            ScrollWindow(hWnd, 0, 5 * (yPos - si.nPos), NULL, NULL);
            UpdateWindow(hWnd);
        }

        return 0;
    }
    case WM_HSCROLL: {
        int id = 0;
        if(lParam != 0)
        {
            id       = GetDlgCtrlID((HWND)lParam);
            if(id < 0 || id >= (int)m_trackbars.size())
            {
                return 0;
            }
            auto pos = SendMessage(m_trackbars[id].trackBarWnd, TBM_GETPOS, 0, 0);
            auto p   = *m_trackbars[id].params.begin();

            float value = p->minValue;
            if(m_trackbars[id].steps > 0)
            {
                value = p->minValue + (p->maxValue - p->minValue) * pos / m_trackbars[id].steps;
            }

            std::string displayText;
            if(m_useNiceView && !m_trackbars[id].stateLabels.empty())
            {
                int labelIndex = (std::max)(0, (std::min)((int)pos, (int)m_trackbars[id].stateLabels.size() - 1));
                displayText = m_trackbars[id].stateLabels[labelIndex];
            }
            else if(m_useNiceView)
            {
                displayText = FormatNumericValue(value, m_trackbars[id].displayPrecision);
            }
            else
            {
                displayText = std::to_string(value);
            }

            if(m_trackbars[id].paramValueWnd)
                SetWindowText(m_trackbars[id].paramValueWnd, convertCharArrayToLPCWSTR(displayText.c_str()));

            for(auto& tp : m_trackbars[id].params)
            {
                tp->currentValue = value;
            }

            m_captureManager.UpdateParams();
        }
        return 0;
    }
    case WM_COMMAND: {
        UINT controlId   = LOWORD(wParam);
        UINT notifyCode  = HIWORD(wParam);
        switch(notifyCode)
        {
        case BN_CLICKED: {
            if(lParam == (LPARAM)m_closeButtonWnd)
            {
                ShowWindow(m_mainWindow, SW_HIDE);
            }
            else if(lParam == (LPARAM)m_resetButtonWnd)
            {
                m_captureManager.ResetParams();
                RebuildControls(true);
            }
            else if(lParam == (LPARAM)m_viewModeToggleWnd)
            {
                m_useNiceView = SendMessage(m_viewModeToggleWnd, BM_GETCHECK, 0, 0) == BST_CHECKED;
                RebuildControls(true);
            }
            return 0;
        }
        }

        switch(controlId)
        {
        case IDM_UPDATE_PARAMS: {
            RebuildControls(true);
            return 0;
        }
        }
        break;
    }
    }
    return DefWindowProc(hWnd, message, wParam, lParam);
}

void ParamsWindow::AddTrackbar(UINT iMin, UINT iMax, UINT iStart, UINT iSteps, const char* name, ShaderParam* p)
{
    // de-dupe parameters
    for(auto& t : m_trackbars)
    {
        if(strcmp(t.paramName, name) == 0 && t.def == iStart && t.steps == iSteps)
        {
            t.params.push_back(p);
            return;
        }
    }

    const char* sourceText = p->description.size() ? p->description.c_str() : name;
    auto displayParts = ParseDisplayTextParts(sourceText);
    auto labelText = ParseStateLabelText(displayParts.label.c_str());

    HWND hwndTrack = NULL;
    HWND paramNameWnd = NULL;
    HWND paramValueWnd = NULL;
    bool useStateLabels = false;
    int  displayPrecision = GetStepPrecision(p->stepValue);

    if(m_useNiceView)
    {
        if(!labelText.stateLabels.empty() && labelText.stateLabels.size() == iSteps + 1)
        {
            useStateLabels = true;
        }
        else if(iSteps == 1)
        {
            labelText.stateLabels = {"OFF", "ON"};
            useStateLabels        = true;
        }
    }

    hwndTrack = CreateWindowEx(0,
                               TRACKBAR_CLASS,
                               L"Trackbar Control",
                               WS_CHILD | WS_VISIBLE | TBS_AUTOTICKS,
                               0,
                               0,
                               1,
                               (LONG)(m_dpiScale * TRACK_HEIGHT),
                               m_mainWindow,
                               (HMENU)m_trackbars.size(),
                               m_instance,
                               NULL);
    SetWindowSubclass(hwndTrack, TrackbarSubclassProc, 1, 0);

    SendMessage(hwndTrack,
                TBM_SETRANGE,
                (WPARAM)TRUE, // redraw flag
                (LPARAM)MAKELONG(iMin, iMax));

    SendMessage(hwndTrack,
                TBM_SETPOS,
                (WPARAM)TRUE, // redraw flag
                (LPARAM)iStart);

    SendMessage(hwndTrack, WM_SETFONT, (LPARAM)m_font, true);

    paramNameWnd = CreateWindowEx(0,
                                  L"STATIC",
                                  convertCharArrayToLPCWSTR(displayParts.label.c_str()),
                                  SS_RIGHT | SS_NOTIFY | WS_CHILD | WS_VISIBLE,
                                  0,
                                  0,
                                  1,
                                  1,
                                  m_mainWindow,
                                  NULL,
                                  m_instance,
                                  NULL);
    SendMessage(paramNameWnd, WM_SETFONT, (LPARAM)m_font, true);

    float value = p->minValue;
    if(iSteps > 0)
    {
        value = p->minValue + (p->maxValue - p->minValue) * iStart / iSteps;
    }

    std::string displayText;
    if(useStateLabels)
    {
        int labelIndex = (std::max)(0, (std::min)((int)iStart, (int)labelText.stateLabels.size() - 1));
        displayText = labelText.stateLabels[labelIndex];
    }
    else if(m_useNiceView)
    {
        displayText = FormatNumericValue(value, displayPrecision);
    }
    else
    {
        displayText = std::to_string(value);
    }

    paramValueWnd = CreateWindowEx(0,
                                   L"STATIC",
                                   convertCharArrayToLPCWSTR(displayText.c_str()),
                                   SS_LEFT | WS_CHILD | WS_VISIBLE,
                                   0,
                                   0,
                                   1,
                                   1,
                                   m_mainWindow,
                                   NULL,
                                   m_instance,
                                   NULL);
    SendMessage(paramValueWnd, WM_SETFONT, (LPARAM)m_font, true);

    // tooltip
    {
        std::string tooltipText = p->name;
        if(!displayParts.tooltipPrefix.empty())
        {
            tooltipText = displayParts.tooltipPrefix + " - " + p->name;
        }

        if(!tooltipText.empty())
        {
            // Associate the tooltip with the tool.
            TOOLINFO toolInfo = {0};
            toolInfo.cbSize   = sizeof(toolInfo);
            toolInfo.hwnd     = m_mainWindow;
            toolInfo.uFlags   = TTF_IDISHWND | TTF_SUBCLASS;
            toolInfo.uId      = (UINT_PTR)(paramNameWnd ? paramNameWnd : hwndTrack);
            toolInfo.lpszText = convertCharArrayToLPCWSTR(tooltipText.c_str());
            SendMessage(m_hwndTip, TTM_ADDTOOL, 0, (LPARAM)&toolInfo);

            toolInfo.uId = (UINT_PTR)hwndTrack;
            SendMessage(m_hwndTip, TTM_ADDTOOL, 0, (LPARAM)&toolInfo);
        }
    }

    ParamsTrackbar pt;
    pt.paramName     = name;
    pt.min           = p->minValue;
    pt.max           = p->maxValue;
    pt.step          = p->stepValue;
    pt.val           = p->currentValue;
    pt.trackBarWnd   = hwndTrack;
    pt.paramNameWnd  = paramNameWnd;
    pt.paramValueWnd = paramValueWnd;
    pt.def           = iStart;
    pt.steps         = iSteps;
    pt.displayPrecision = displayPrecision;
    if(useStateLabels)
    {
        pt.stateLabels = labelText.stateLabels;
    }
    pt.params.push_back(p);

    m_trackbars.emplace_back(pt);

    SCROLLINFO si = {};
    si.cbSize     = sizeof(si);
    si.fMask      = SIF_POS;
    GetScrollInfo(m_mainWindow, SB_VERT, &si);
    LayoutTrackbarControl(m_trackbars.back(), m_trackbars.size() - 1, si.nPos);
}

bool ParamsWindow::Create(_In_ HINSTANCE hInstance, _In_ int nCmdShow, _In_ HWND shaderWindow)
{
    m_shaderWindow = shaderWindow;

    LoadStringW(hInstance, IDS_PARAM_TITLE, m_title, MAX_LOADSTRING);
    LoadStringW(hInstance, IDC_SHADERPARAMS, m_windowClass, MAX_LOADSTRING);
    MyRegisterClass(hInstance);
    if(!InitInstance(hInstance, nCmdShow))
    {
        return FALSE;
    }

    return TRUE;
}
